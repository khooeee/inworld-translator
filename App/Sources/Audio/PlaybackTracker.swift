import Foundation
import Synchronization

/// Counts speech buffers through the player, so `play` can wait until the
/// last one has been heard. Completion handlers arrive on an audio thread.
final class PlaybackTracker: Sendable {
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
