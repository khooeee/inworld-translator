import Foundation
import Synchronization

/// Mutes capture for speaker playback and its echo tail. The route observer
/// updates the same gate that the audio tap reads.
final class SpeechGate: Sendable {
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
