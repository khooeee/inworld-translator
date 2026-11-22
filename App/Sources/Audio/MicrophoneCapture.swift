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
/// The microphone stays open with headphones and uses a short mute window
/// for loudspeaker playback to prevent the app from translating its own voice.
actor MicrophoneCapture: AudioCapturing, SpeechPlaying {
    private static let log = Logger(subsystem: "InworldTranslator", category: "audio")

    private struct CaptureGraph {
        let id = UUID()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
    }

    private let speechFormat = AVAudioFormat(standardFormatWithSampleRate: Double(SpeechAudio.sampleRate), channels: 1)!
    private let gate = SpeechGate()
    private var graph: CaptureGraph?
    private var playback: PlaybackTracker?
    private var converter: PCMConverter?
    private var chunks: AsyncStream<AudioChunk>.Continuation?
    private var events: AsyncStream<AudioCaptureEvent>.Continuation?
    private var observers: [any NSObjectProtocol] = []
    private var isInterrupted = false

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
        gate.updateRoute(allowsListening: Self.currentOutputAllowsListening())
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
        Self.log.info("Capturing at \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
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

    private static func currentOutputAllowsListening() -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        let handsFreeInput = route.inputs.first { $0.portType == .bluetoothHFP }
        // Every active output must qualify. A generic Bluetooth output can
        // be a speaker; a processed hands-free route has its own echo handling.
        return !route.outputs.isEmpty && route.outputs.allSatisfy { output in
            switch output.portType {
            case .headphones:
                return true
            case .bluetoothHFP:
                guard let handsFreeInput else { return false }
                return output.hasHardwareVoiceCallProcessing || handsFreeInput.hasHardwareVoiceCallProcessing
            default:
                return false
            }
        }
    }

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

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [gate] note in
            // Update the gate before any asynchronous engine restart.
            gate.updateRoute(allowsListening: Self.currentOutputAllowsListening())
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
        gate.updateRoute(allowsListening: Self.currentOutputAllowsListening())
        gate.startPlayback()
        defer {
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

/// Mutes capture for speaker playback and its echo tail. The route observer
/// updates the same gate that the audio tap reads.
private final class SpeechGate: Sendable {
    private static let echoTail: Duration = .milliseconds(300)

    private struct State {
        var playing = false
        var allowsListening = false
        var mutedUntil: ContinuousClock.Instant?
    }

    private let state = Mutex(State())

    var isMuted: Bool {
        state.withLock { state in
            (state.playing && !state.allowsListening) || state.mutedUntil.map { ContinuousClock.now < $0 } ?? false
        }
    }

    func updateRoute(allowsListening: Bool) {
        state.withLock {
            if $0.playing, !$0.allowsListening, allowsListening {
                $0.mutedUntil = .now + Self.echoTail
            }
            $0.allowsListening = allowsListening
        }
    }

    func startPlayback() {
        state.withLock { $0.playing = true }
    }

    func stopPlayback() {
        state.withLock {
            if $0.playing, !$0.allowsListening {
                $0.mutedUntil = .now + Self.echoTail
            }
            $0.playing = false
        }
    }

    func reset() {
        state.withLock { $0 = State() }
    }
}

/// Counts speech buffers through the player, so `play` can wait until the
/// last one has been heard. Completion handlers arrive on an audio thread.
private final class PlaybackTracker: Sendable {
    private struct State {
        var outstanding = 0
        var cancelled = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func scheduled() {
        state.withLock { $0.outstanding += 1 }
    }

    func played() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.outstanding -= 1
            guard state.outstanding <= 0 else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Ends playback early: whoever is waiting returns now.
    func cancel() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.cancelled = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Returns once every scheduled buffer has played, or on cancel.
    func waitUntilPlayed() async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> Bool in
                if state.cancelled || state.outstanding <= 0 { return true }
                state.waiter = continuation
                return false
            }
            if done { continuation.resume() }
        }
    }
}

/// Converts tap buffers to 16 kHz mono PCM16 and cuts them into 100 ms chunks.
/// While the gate is muted, the audio is replaced with silence.
///
/// Used only from the audio tap, which runs its callbacks one at a time on a
/// single thread; the lock makes that assumption safe rather than relying on it.
private final class PCMConverter: Sendable {
    private static let outputRate = 16_000.0
    private static let chunkSamples = 1600 // 100 ms

    private struct State: @unchecked Sendable {
        // AVAudioConverter and AVAudioPCMBuffer are not Sendable; they never
        // leave this lock.
        let converter: AVAudioConverter
        let output: AVAudioPCMBuffer
        var pending: [Int16] = []
    }

    private let state: Mutex<State>
    private let chunks: AsyncStream<AudioChunk>.Continuation
    private let gate: SpeechGate

    init?(from input: AVAudioFormat, chunks: AsyncStream<AudioChunk>.Continuation, gate: SpeechGate) {
        guard
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.outputRate, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: input, to: outputFormat),
            // Room for a 2048-frame tap buffer at up to 48 kHz, with margin.
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)
        else { return nil }
        state = Mutex(State(converter: converter, output: output))
        self.chunks = chunks
        self.gate = gate
    }

    func convert(_ buffer: AVAudioPCMBuffer) {
        // The tap's buffer is only valid during the callback; the converter
        // copies out of it synchronously below.
        nonisolated(unsafe) let input = buffer
        let ready: [Data] = state.withLock { state in
            var consumed = false
            var error: NSError?
            state.output.frameLength = 0
            let status = state.converter.convert(to: state.output, error: &error) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, let samples = state.output.int16ChannelData?[0] else { return [] }
            let count = Int(state.output.frameLength)
            if gate.isMuted {
                state.pending.append(contentsOf: repeatElement(0, count: count))
            } else {
                state.pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
            }

            var ready: [Data] = []
            while state.pending.count >= Self.chunkSamples {
                let chunk = state.pending.prefix(Self.chunkSamples)
                ready.append(chunk.withUnsafeBytes { Data($0) })
                state.pending.removeFirst(Self.chunkSamples)
            }
            return ready
        }
        for pcm in ready {
            chunks.yield(AudioChunk(pcm: pcm, level: PCMFileAudioSource.level(of: pcm)))
        }
    }
}
