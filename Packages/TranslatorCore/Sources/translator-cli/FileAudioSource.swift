import Foundation
import Synchronization
import TranslatorCore

/// Plays PCM files into a session as if they were the microphone: 100 ms
/// chunks at real-time pace (or faster), with silence between files so each
/// one ends a turn, and silence after the last one until the session stops.
final class FileAudioSource: AudioCapturing {
    struct Clip: Sendable {
        let id: String
        let pcm: Data
    }

    /// When each clip's audio started and finished going out.
    struct Playback: Sendable {
        let id: String
        let startedAt: Date
        var endedAt: Date?
    }

    private struct State {
        var player: Task<Void, Never>?
        var chunks: AsyncStream<AudioChunk>.Continuation?
        var events: AsyncStream<AudioCaptureEvent>.Continuation?
        var playback: [Playback] = []
        var bytesSent = 0
        var finished = false
    }

    private let playlist: [Clip]
    private let speed: Double
    private let gap: Duration
    private let state = Mutex(State())
    private static let chunkBytes = 3200 // 100 ms at 16 kHz mono PCM16

    init(playlist: [Clip], speed: Double, gap: Duration = .milliseconds(1500)) {
        self.playlist = playlist
        self.speed = speed
        self.gap = gap
    }

    var playback: [Playback] { state.withLock { $0.playback } }
    var audioSeconds: Double { Double(state.withLock { $0.bytesSent }) / 32_000 }
    var isFinished: Bool { state.withLock { $0.finished } }

    func start() async throws -> AudioCaptureStream {
        let (chunks, chunkContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(50))
        let (events, eventContinuation) = AsyncStream<AudioCaptureEvent>.makeStream()
        let player = Task { [self, playlist, speed, gap] in
            let interval = Duration.milliseconds(100) / speed
            let clock = ContinuousClock()
            var next = clock.now
            let silence = Data(count: Self.chunkBytes)

            func send(_ pcm: Data) async -> Bool {
                next += interval
                try? await clock.sleep(until: next)
                if Task.isCancelled { return false }
                self.state.withLock { $0.bytesSent += pcm.count }
                chunkContinuation.yield(AudioChunk(pcm: pcm, level: Self.level(of: pcm)))
                return true
            }
            func sendSilence(_ duration: Duration) async -> Bool {
                for _ in 0..<Int((duration / .milliseconds(100)).rounded()) {
                    guard await send(silence) else { return false }
                }
                return true
            }

            guard await sendSilence(.milliseconds(500)) else { return }
            for clip in playlist {
                self.state.withLock { $0.playback.append(Playback(id: clip.id, startedAt: Date())) }
                var offset = 0
                while offset < clip.pcm.count {
                    let end = min(clip.pcm.count, offset + Self.chunkBytes)
                    guard await send(clip.pcm.subdata(in: offset..<end)) else { return }
                    offset = end
                }
                self.state.withLock { $0.playback[$0.playback.count - 1].endedAt = Date() }
                guard await sendSilence(gap) else { return }
            }
            self.state.withLock { $0.finished = true }
            // Like a microphone in a quiet room, keep going until stopped.
            while await send(silence) {}
        }
        state.withLock {
            $0.player = player
            $0.chunks = chunkContinuation
            $0.events = eventContinuation
        }
        return AudioCaptureStream(chunks: chunks, events: events)
    }

    func stop() async {
        let (player, chunks, events) = state.withLock { state in
            defer {
                state.player = nil
                state.chunks = nil
                state.events = nil
            }
            return (state.player, state.chunks, state.events)
        }
        player?.cancel()
        await player?.value
        chunks?.finish()
        events?.finish()
    }

    private static func level(of pcm: Data) -> Float {
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            let rms = (sum / Double(samples.count)).squareRoot() / Double(Int16.max)
            return Float(min(1, rms * 4))
        }
    }
}

/// Always online; the harness does not simulate network changes.
struct AlwaysOnline: ConnectivityMonitoring {
    func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(true)
        }
    }
}

/// Passes translations through and adds up the tokens they were billed for.
final class MeteredTranslator: Translating {
    private let inner: any Translating
    private let totals = Mutex((prompt: 0, completion: 0, requests: 0, models: [String: Int]()))

    init(_ inner: any Translating) {
        self.inner = inner
    }

    var usage: (prompt: Int, completion: Int, requests: Int, models: [String: Int]) {
        totals.withLock { $0 }
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationUpdate, Error> {
        let upstream = inner.translate(request)
        totals.withLock { $0.requests += 1 }
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    for try await update in upstream {
                        if case .usage(let prompt, let completion, let model) = update {
                            self.totals.withLock {
                                $0.prompt += prompt
                                $0.completion += completion
                                if let model { $0.models[model, default: 0] += 1 }
                            }
                        }
                        continuation.yield(update)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
