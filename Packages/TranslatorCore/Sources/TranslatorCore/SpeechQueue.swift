import Foundation
import Synchronization

/// Speaks English translations aloud, one at a time, in the order given.
///
/// Speech waits while someone is mid-sentence (the floor is taken), so the
/// phone does not talk over the conversation it is translating. The queue is
/// short: when it overflows, the oldest waiting phrase is skipped, because
/// hearing what was just said matters more than catching up. Its methods are
/// synchronous, so requests are handled in exactly the order they were made.
public final class SpeechQueue: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Phrases allowed to wait behind the one being spoken.
        public var maxWaiting = 2

        public init() {}
    }

    public enum Event: Sendable, Equatable {
        /// This phrase is being spoken; nil once nothing is.
        case speaking(PhraseID?)
        /// A phrase could not be spoken. The error is nil when the failure
        /// was not the service's, such as the speaker being unavailable.
        case failed(ServiceError?)
    }

    /// Everything that happens, in order. Single consumer.
    public let events: AsyncStream<Event>

    private struct Item {
        let id: PhraseID
        let text: String
    }

    private struct State {
        var waiting: [Item] = []
        var current: (id: PhraseID, task: Task<Void, Never>)?
        var floorTaken = false
    }

    private let synthesizer: any SpeechSynthesizing
    private let player: any SpeechPlaying
    private let configuration: Configuration
    private let continuation: AsyncStream<Event>.Continuation
    private let state = Mutex(State())

    public init(synthesizer: any SpeechSynthesizing, player: any SpeechPlaying, configuration: Configuration = Configuration()) {
        self.synthesizer = synthesizer
        self.player = player
        self.configuration = configuration
        (events, continuation) = AsyncStream<Event>.makeStream()
    }

    deinit {
        continuation.finish()
    }

    public func enqueue(id: PhraseID, text: String) {
        state.withLock { state in
            state.waiting.append(Item(id: id, text: text))
            if state.waiting.count > configuration.maxWaiting {
                state.waiting.removeFirst(state.waiting.count - configuration.maxWaiting)
            }
            startNext(&state)
        }
    }

    /// Whether someone is speaking. Nothing new starts while they are; a
    /// phrase already being spoken carries on.
    public func setFloorTaken(_ taken: Bool) {
        state.withLock { state in
            state.floorTaken = taken
            startNext(&state)
        }
    }

    /// Forgets what is waiting and stops what is being spoken, without
    /// waiting for the sound to stop.
    public func cancelAll() {
        _ = cancel()
    }

    /// Forgets what is waiting and stops what is being spoken. Returns once
    /// the sound has stopped.
    public func stop() async {
        await cancel()?.value
    }

    private func cancel() -> Task<Void, Never>? {
        state.withLock { state in
            state.waiting.removeAll()
            state.current?.task.cancel()
            return state.current?.task
        }
    }

    // MARK: Speaking

    /// One phrase at a time: the next starts when the current one finishes,
    /// so a stopping phrase never overlaps the one after it.
    private func startNext(_ state: inout State) {
        guard state.current == nil, !state.floorTaken, !state.waiting.isEmpty else { return }
        let item = state.waiting.removeFirst()
        let task = Task {
            await self.speak(item)
            self.finished(item.id)
        }
        state.current = (item.id, task)
        continuation.yield(.speaking(item.id))
    }

    private func speak(_ item: Item) async {
        do {
            try await player.play(synthesizer.synthesize(item.text))
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            continuation.yield(.failed(error as? ServiceError))
        }
    }

    private func finished(_ id: PhraseID) {
        state.withLock { state in
            guard state.current?.id == id else { return }
            state.current = nil
            startNext(&state)
            if state.current == nil {
                continuation.yield(.speaking(nil))
            }
        }
    }
}
