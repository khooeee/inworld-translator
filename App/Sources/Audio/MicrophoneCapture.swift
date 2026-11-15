import AVFAudio
import Foundation
import os
import Synchronization
import TranslatorCore

/// Captures the microphone with `AVAudioEngine` and delivers 100 ms chunks of
/// 16 kHz mono PCM16, which is what Inworld STT expects.
///
/// Recovers by itself from route changes (headphones, Bluetooth, unplugging),
/// and reports interruptions such as phone calls so the session can pause.
actor MicrophoneCapture: AudioCapturing {
    private static let log = Logger(subsystem: "InworldTranslator", category: "audio")

    private let engine = AVAudioEngine()
    private var converter: PCMConverter?
    private var chunks: AsyncStream<AudioChunk>.Continuation?
    private var events: AsyncStream<AudioCaptureEvent>.Continuation?
    private var observers: [any NSObjectProtocol] = []
    private var isRunning = false
    private var isInterrupted = false

    // MARK: AudioCapturing

    func start() async throws -> AudioCaptureStream {
        await stop()
        guard await Self.requestPermission() else { throw AudioCaptureError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            // Default mode keeps the system's gain control, which helps with
            // speakers at different distances from the phone.
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {
            Self.log.error("Audio session setup failed: \(error.localizedDescription, privacy: .public)")
            throw AudioCaptureError.unavailable
        }

        // Five seconds of audio at most. If the network falls that far
        // behind, the oldest audio goes first.
        let (chunkStream, chunkContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(50))
        let (eventStream, eventContinuation) = AsyncStream<AudioCaptureEvent>.makeStream()
        chunks = chunkContinuation
        events = eventContinuation

        do {
            try startEngine()
        } catch {
            Self.log.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            await stop()
            throw AudioCaptureError.unavailable
        }
        isRunning = true
        observeSystemEvents()
        return AudioCaptureStream(chunks: chunkStream, events: eventStream)
    }

    func stop() async {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        if isRunning {
            // Let other apps' audio resume now that the microphone is free.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        isRunning = false
        isInterrupted = false
        chunks?.finish()
        events?.finish()
        chunks = nil
        events = nil
    }

    // MARK: Engine

    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.unavailable
        }
        guard let chunks, let converter = PCMConverter(from: format, chunks: chunks) else {
            throw AudioCaptureError.unavailable
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            converter.convert(buffer)
        }
        engine.prepare()
        try engine.start()
        Self.log.info("Capturing at \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
    }

    /// Rebuilds the tap for a new input format and restarts.
    private func restartEngine(reason: String) {
        guard isRunning, !isInterrupted else { return }
        Self.log.info("Restarting audio engine: \(reason, privacy: .public)")
        engine.stop()
        do {
            try startEngine()
        } catch {
            Self.log.error("Audio engine restart failed: \(error.localizedDescription, privacy: .public)")
            events?.yield(.failed)
        }
    }

    // MARK: System events

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            Task { await self?.interruption(type, shouldResume: options.contains(.shouldResume)) }
        })

        // Headphones, Bluetooth, and other route changes can change the input
        // format. The engine stops itself and posts this notification.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { await self?.restartEngine(reason: "configuration change") }
        })

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            Self.log.info("Audio route changed: \(String(describing: reason?.rawValue), privacy: .public)")
        })

        // The audio server restarted; every audio object is now invalid.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            Task { await self?.mediaServicesReset() }
        })
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        guard isRunning else { return }
        switch type {
        case .began:
            isInterrupted = true
            engine.stop()
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
                try startEngine()
                events?.yield(.interruptionEnded(resumed: true))
            } catch {
                Self.log.error("Could not resume after interruption: \(error.localizedDescription, privacy: .public)")
                events?.yield(.interruptionEnded(resumed: false))
            }
        default:
            break
        }
    }

    private func mediaServicesReset() {
        guard isRunning else { return }
        events?.yield(.failed)
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

/// Converts tap buffers to 16 kHz mono PCM16 and cuts them into 100 ms chunks.
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

    init?(from input: AVAudioFormat, chunks: AsyncStream<AudioChunk>.Continuation) {
        guard
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.outputRate, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: input, to: outputFormat),
            // Room for a 2048-frame tap buffer at up to 48 kHz, with margin.
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)
        else { return nil }
        state = Mutex(State(converter: converter, output: output))
        self.chunks = chunks
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
            state.pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(state.output.frameLength)))

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
