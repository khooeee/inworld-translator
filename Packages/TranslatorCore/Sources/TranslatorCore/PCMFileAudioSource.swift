import Foundation
import Synchronization

/// Plays 16 kHz mono PCM16 clips into a session as if they were the
/// microphone: 100 ms chunks at real-time pace (or faster), with silence
/// between clips so each one ends a turn, and silence after the last one
/// until the session stops. For the validation harness and Debug builds.
public final class PCMFileAudioSource: AudioCapturing {
    public struct Clip: Sendable {
        public let id: String
        public let pcm: Data

        public init(id: String, pcm: Data) {
            self.id = id
            self.pcm = pcm
        }
    }

    /// When each clip's audio started and finished going out.
    public struct Playback: Sendable {
        public let id: String
        public let startedAt: Date
        public var endedAt: Date?
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

    public init(playlist: [Clip], speed: Double = 1, gap: Duration = .milliseconds(1500)) {
        self.playlist = playlist
        self.speed = speed
        self.gap = gap
    }

    public var playback: [Playback] { state.withLock { $0.playback } }
    public var audioSeconds: Double { Double(state.withLock { $0.bytesSent }) / 32_000 }
    public var isFinished: Bool { state.withLock { $0.finished } }

    public func start() async throws -> AudioCaptureStream {
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

    public func stop() async {
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

    /// Loudness of a PCM16 chunk on a 0 to 1 scale, for the level meter.
    public static func level(of pcm: Data) -> Float {
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            let rms = (sum / Double(samples.count)).squareRoot() / Double(Int16.max)
            return Float(min(1, rms * 4))
        }
    }
}
