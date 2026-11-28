import AVFAudio
import Foundation
import os
import Synchronization
import TranslatorCore

/// Captures the microphone with `AVAudioEngine` and delivers 100 ms chunks of
/// 16 kHz mono PCM16, which is what Inworld STT expects. Also plays spoken
/// translations through the same engine.
///
/// Recovers by itself from route changes (headphones, Bluetooth, unplugging),
/// and reports interruptions such as phone calls so the session can pause.
///
/// During playback, the microphone stays open on routes that handle echo.
actor MicrophoneCapture: AudioCapturing, SpeechPlaying {
    private static let log = Logger(subsystem: "InworldTranslator", category: "audio")

    private struct CaptureGraph {
        let id = UUID()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        var voiceProcessingEnabled: Bool { engine.inputNode.isVoiceProcessingEnabled }
    }

    private let speechFormat = AVAudioFormat(standardFormatWithSampleRate: Double(SpeechAudio.sampleRate), channels: 1)!
    private let gate = SpeechGate()
    private let speakerVoiceProcessing: Bool
    private var graph: CaptureGraph?
    private var playback: PlaybackTracker?
    private var converter: PCMConverter?
    private var chunks: AsyncStream<AudioChunk>.Continuation?
    private var events: AsyncStream<AudioCaptureEvent>.Continuation?
    private var observers: [any NSObjectProtocol] = []
    private var isInterrupted = false

    init(speakerVoiceProcessing: Bool = true) {
        self.speakerVoiceProcessing = speakerVoiceProcessing
    }

    // MARK: AudioCapturing

    func start() async throws -> AudioCaptureStream {
        stop()
        guard await Self.requestPermission() else { throw AudioCaptureError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            // Default mode keeps the system's gain control, which helps with
            // speakers at different distances from the phone. Play-and-record
            // plays spoken translations through the speaker.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {
            Self.log.error("Audio session setup failed: \(error.localizedDescription, privacy: .public)")
            throw AudioCaptureError.unavailable
        }

        // A voice preview uses a playback-only session. Create the engine
        // after recording is active so its input node sees the recording route.
        let graph = CaptureGraph()
        if speakerVoiceProcessing {
            do {
                try graph.engine.inputNode.setVoiceProcessingEnabled(true)
            } catch {
                Self.log.info("Voice processing unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        self.graph = graph

        // Five seconds of audio at most. If the network falls that far
        // behind, the oldest audio goes first.
        let (chunkStream, chunkContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(50))
        let (eventStream, eventContinuation) = AsyncStream<AudioCaptureEvent>.makeStream()
        chunks = chunkContinuation
        events = eventContinuation

        do {
            try startEngine(graph)
        } catch {
            Self.log.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            stop()
            throw AudioCaptureError.unavailable
        }
        observeSystemEvents(for: graph)
        return AudioCaptureStream(chunks: chunkStream, events: eventStream)
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        cutPlayback()
        if let graph {
            graph.engine.inputNode.removeTap(onBus: 0)
            graph.engine.stop()
            self.graph = nil
            // Let other apps' audio resume now that the microphone is free.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        converter = nil
        gate.reset()
        isInterrupted = false
        chunks?.finish()
        events?.finish()
        chunks = nil
        events = nil
    }

    // MARK: Engine

    private func startEngine(_ graph: CaptureGraph) throws {
        let (engine, player) = (graph.engine, graph.player)
        gate.updateRoute(allowsListening: PlaybackRoute.allowsListening(voiceProcessingEnabled: graph.voiceProcessingEnabled))
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.unavailable
        }
        guard let chunks, let converter = PCMConverter(from: format, chunks: chunks, gate: gate) else {
            throw AudioCaptureError.unavailable
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            converter.convert(buffer)
        }
        if player.engine == nil {
            engine.attach(player)
        }
        engine.connect(player, to: engine.mainMixerNode, format: speechFormat)
        engine.prepare()
        try engine.start()
        Self.log.info("Capturing at \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, voice processing: \(graph.voiceProcessingEnabled, privacy: .public)")
    }

    /// Rebuilds the tap for a new input format and restarts.
    private func restartEngine(captureID: UUID) {
        guard let graph, graph.id == captureID, !isInterrupted else { return }
        Self.log.info("Restarting audio engine after a configuration change")
        cutPlayback()
        graph.engine.stop()
        do {
            try startEngine(graph)
        } catch {
            Self.log.error("Audio engine restart failed: \(error.localizedDescription, privacy: .public)")
            events?.yield(.failed)
        }
    }

    // MARK: System events

    private func observeSystemEvents(for graph: CaptureGraph) {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let captureID = graph.id

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            Task { await self?.interruption(type, shouldResume: options.contains(.shouldResume), captureID: captureID) }
        })

        // Headphones, Bluetooth, and other route changes can change the input
        // format. The engine stops itself and posts this notification.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: graph.engine, queue: nil) { [weak self] _ in
            Task { await self?.restartEngine(captureID: captureID) }
        })

        let voiceProcessingEnabled = graph.voiceProcessingEnabled
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [gate] note in
            // Update the gate before any asynchronous engine restart.
            gate.updateRoute(allowsListening: PlaybackRoute.allowsListening(voiceProcessingEnabled: voiceProcessingEnabled))
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            Self.log.info("Audio route changed: \(String(describing: reason?.rawValue), privacy: .public)")
        })

        // The audio server restarted; every audio object is now invalid.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            Task { await self?.mediaServicesReset(captureID: captureID) }
        })
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool, captureID: UUID) {
        guard let graph, graph.id == captureID else { return }
        switch type {
        case .began:
            isInterrupted = true
            cutPlayback()
            graph.engine.stop()
            events?.yield(.interruptionBegan)
        case .ended:
            guard isInterrupted else { return }
            isInterrupted = false
            guard shouldResume else {
                events?.yield(.interruptionEnded(resumed: false))
                return
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try startEngine(graph)
                events?.yield(.interruptionEnded(resumed: true))
            } catch {
                Self.log.error("Could not resume after interruption: \(error.localizedDescription, privacy: .public)")
                events?.yield(.interruptionEnded(resumed: false))
            }
        default:
            break
        }
    }

    private func mediaServicesReset(captureID: UUID) {
        guard graph?.id == captureID else { return }
        events?.yield(.failed)
    }

    // MARK: SpeechPlaying

    func play(_ audio: AsyncThrowingStream<Data, any Error>) async throws {
        guard let graph, !isInterrupted, graph.engine.isRunning else { throw AudioCaptureError.unavailable }
        let (engine, player) = (graph.engine, graph.player)
        if playback != nil { cutPlayback() }
        let tracker = PlaybackTracker()
        playback = tracker
        let listening = PlaybackRoute.allowsListening(voiceProcessingEnabled: graph.voiceProcessingEnabled)
        gate.updateRoute(allowsListening: listening)
        gate.startPlayback()
        _ = converter?.takePeak()
        Self.log.info("Speaking with mic \(listening ? "open" : "muted", privacy: .public), voice processing: \(graph.voiceProcessingEnabled, privacy: .public), \(PlaybackRoute.summary, privacy: .public)")
        defer {
            Self.log.info("Finished speaking; loudest mic input: \(self.converter?.takePeak() ?? 0, format: .fixed(precision: 3), privacy: .public)")
            if playback === tracker { cutPlayback() }
        }

        try await withTaskCancellationHandler {
            // Chunks need not hold whole samples; carry a stray byte over.
            var pending = Data()
            for try await data in audio {
                guard !tracker.isCancelled else { break }
                pending.append(data)
                let usable = pending.count - pending.count % 2
                guard usable > 0, let buffer = makeBuffer(pending.prefix(usable)) else { continue }
                pending.removeFirst(usable)
                // Starting a player on a stopped engine raises an exception.
                guard engine.isRunning else {
                    tracker.cancel()
                    break
                }
                tracker.scheduled()
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                    tracker.played()
                }
                if !player.isPlaying {
                    player.play()
                }
            }
            await tracker.waitUntilPlayed()
        } onCancel: {
            tracker.cancel()
        }
        try Task.checkCancellation()
    }

    /// Stops speech at once, for when the engine is about to stop.
    private func cutPlayback() {
        playback?.cancel()
        playback = nil
        graph?.player.stop()
        gate.stopPlayback()
    }

    private func makeBuffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        pcm.withUnsafeBytes { raw in
            for index in 0..<frames {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                channel[index] = Float(sample) / 32_768
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    // MARK: Permission

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}
