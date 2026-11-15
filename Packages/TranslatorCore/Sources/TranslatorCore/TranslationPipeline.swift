import Foundation

/// Translates finalized phrases without letting slow responses pile up.
///
/// A few requests run at once; the rest wait in a short queue. When the queue
/// is full the oldest waiting phrase is skipped, because for live captions a
/// current translation is worth more than a complete backlog. Every request
/// has a deadline. Updates carry the phrase ID, so a late response can only
/// ever land on its own phrase.
public actor TranslationPipeline {
    public struct Configuration: Sendable, Equatable {
        /// Requests in flight at once.
        public var maxConcurrent = 2
        /// Phrases allowed to wait behind them.
        public var maxWaiting = 6
        public var requestTimeout: Duration = .seconds(12)
        /// Earlier phrases sent along for reference.
        public var contextSize = 3
        /// Total tries per phrase, for failures that might be momentary.
        public var maxAttempts = 2
        public var retryDelay: Duration = .milliseconds(300)

        public init() {}
    }

    public struct Update: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// The request is starting, or starting over after a failed try.
            case pending
            case language(String)
            /// All of the translated text received so far.
            case partial(String)
            case completed(String, language: String?)
            case unavailable(TranslationUnavailableReason, error: BackendError?)
        }

        public let id: PhraseID
        public let kind: Kind
    }

    /// Updates for all phrases, in the order they happened. Single consumer.
    public nonisolated let updates: AsyncStream<Update>

    private struct Job {
        let id: PhraseID
        let text: String
    }

    private struct HistoryEntry {
        let id: PhraseID
        let source: String
        var translation: String?
    }

    private let translator: any Translating
    private let configuration: Configuration
    private let continuation: AsyncStream<Update>.Continuation

    private var waiting: [Job] = []
    private var running: [PhraseID: Task<Void, Never>] = [:]
    private var history: [HistoryEntry] = []
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(translator: any Translating, configuration: Configuration = Configuration()) {
        self.translator = translator
        self.configuration = configuration
        (updates, continuation) = AsyncStream<Update>.makeStream()
    }

    public var isIdle: Bool {
        waiting.isEmpty && running.isEmpty
    }

    /// Queues a finalized phrase for translation.
    public func submit(id: PhraseID, text: String) {
        history.append(HistoryEntry(id: id, source: text, translation: nil))
        let historyLimit = configuration.contextSize + configuration.maxConcurrent + configuration.maxWaiting + 1
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }

        waiting.append(Job(id: id, text: text))
        while waiting.count > configuration.maxWaiting {
            let dropped = waiting.removeFirst()
            emit(dropped.id, .unavailable(.skipped, error: nil))
        }
        startWaitingJobs()
    }

    /// Cancels everything queued or in flight and reports each phrase as
    /// cancelled. Returns once all of those reports have been emitted.
    public func cancelAll() async {
        let dropped = waiting
        waiting.removeAll()
        for job in dropped {
            emit(job.id, .unavailable(.cancelled, error: nil))
        }
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    /// Returns when nothing is queued or in flight, or when the caller is
    /// cancelled, whichever comes first.
    public func waitUntilIdle() async {
        guard !isIdle else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                idleWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.resumeIdleWaiter(waiterID) }
        }
    }

    // MARK: Scheduling

    private func startWaitingJobs() {
        while running.count < configuration.maxConcurrent, !waiting.isEmpty {
            let job = waiting.removeFirst()
            let request = TranslationRequest(text: job.text, context: context(before: job.id))
            running[job.id] = Task { [translator, configuration, continuation] in
                let outcome = await Self.run(request, translator: translator, configuration: configuration) { kind in
                    continuation.yield(Update(id: job.id, kind: kind))
                }
                self.finish(job.id, outcome: outcome)
            }
        }
    }

    private func finish(_ id: PhraseID, outcome: Update.Kind) {
        running[id] = nil
        if case .completed(let translation, _) = outcome,
           let index = history.firstIndex(where: { $0.id == id }) {
            history[index].translation = translation
        }
        emit(id, outcome)
        startWaitingJobs()
        if isIdle {
            let waiters = idleWaiters.values
            idleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func resumeIdleWaiter(_ id: UUID) {
        idleWaiters.removeValue(forKey: id)?.resume()
    }

    private func emit(_ id: PhraseID, _ kind: Update.Kind) {
        continuation.yield(Update(id: id, kind: kind))
    }

    /// The phrases just before `id`, oldest first, with their translations
    /// where those have already arrived.
    private func context(before id: PhraseID) -> [TranslationContextItem] {
        history
            .filter { $0.id < id }
            .suffix(configuration.contextSize)
            .map { TranslationContextItem(source: $0.source, translation: $0.translation) }
    }

    // MARK: One translation

    /// Performs the request, reporting progress through `progress`, and
    /// returns the terminal update for the phrase.
    private static func run(
        _ request: TranslationRequest,
        translator: any Translating,
        configuration: Configuration,
        progress: @escaping @Sendable (Update.Kind) -> Void
    ) async -> Update.Kind {
        var attempt = 1
        while true {
            progress(.pending)
            do {
                let (translation, language) = try await withTimeout(configuration.requestTimeout) {
                    var language: String?
                    var text = ""
                    for try await update in translator.translate(request) {
                        switch update {
                        case .language(let code):
                            language = code
                            progress(.language(code))
                        case .delta(let delta):
                            text += delta
                            progress(.partial(text))
                        case .completed(let translation, let finalLanguage):
                            return (translation, finalLanguage ?? language)
                        }
                    }
                    try Task.checkCancellation()
                    throw BackendError.invalidResponse
                }
                let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return .unavailable(.unintelligible, error: nil)
                }
                return .completed(trimmed, language: language)
            } catch {
                if Task.isCancelled { return .unavailable(.cancelled, error: nil) }
                let backendError = error as? BackendError
                switch backendError {
                case .rateLimited, .quotaExceeded:
                    return .unavailable(.limitReached, error: backendError)
                case .some(let failure) where failure.isTransient && attempt < configuration.maxAttempts:
                    attempt += 1
                    try? await Task.sleep(for: configuration.retryDelay)
                    if Task.isCancelled { return .unavailable(.cancelled, error: nil) }
                default:
                    // Includes timeouts: by then the phrase is stale, so do not retry.
                    return .unavailable(.failed, error: backendError)
                }
            }
        }
    }
}
