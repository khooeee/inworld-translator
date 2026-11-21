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
            case language(String, targetLanguage: TargetLanguage? = nil)
            /// All of the translated text received so far.
            case partial(String)
            case completed(String, language: String?, targetLanguage: TargetLanguage? = nil)
            case unavailable(TranslationUnavailableReason, error: ServiceError?)
        }

        public let id: PhraseID
        public let kind: Kind
    }

    /// Updates for all phrases, in the order they happened. Single consumer.
    public nonisolated let updates: AsyncStream<Update>

    private struct Job {
        let id: PhraseID
        let text: String
        let sourceLanguage: TranslationLanguage?
        let targetLanguage: TargetLanguage
        let bidirectional: Bool
    }

    private struct HistoryEntry {
        let job: Job
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
    public func submit(
        id: PhraseID,
        text: String,
        sourceLanguage: TranslationLanguage? = nil,
        targetLanguage: TargetLanguage = .english,
        bidirectional: Bool = false
    ) {
        let job = Job(
            id: id,
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            bidirectional: bidirectional
        )
        history.append(HistoryEntry(job: job, translation: nil))
        let historyLimit = configuration.contextSize + configuration.maxConcurrent + configuration.maxWaiting + 1
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }

        waiting.append(job)
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
            let request = TranslationRequest(
                text: job.text,
                context: context(before: job),
                sourceLanguage: job.sourceLanguage,
                targetLanguage: job.targetLanguage,
                bidirectional: job.bidirectional
            )
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
        if case .completed(let translation, _, _) = outcome,
           let index = history.firstIndex(where: { $0.job.id == id }) {
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

    /// Earlier phrases, with any translations in the request's target language.
    private func context(before job: Job) -> [TranslationContextItem] {
        // A previous turn can point in the opposite direction. Route and
        // translate each two-way phrase on its own.
        guard !job.bidirectional else { return [] }
        return history
            .filter { $0.job.id < job.id }
            .suffix(configuration.contextSize)
            .map { entry in
                let previous = entry.job
                let sameTarget = !previous.bidirectional && previous.targetLanguage == job.targetLanguage
                return TranslationContextItem(
                    source: previous.text,
                    translation: sameTarget ? entry.translation : nil
                )
            }
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
        var nextRequest = request
        if request.bidirectional, let first = request.sourceLanguage,
           let source = TranscriptLanguage.source(in: request.text, between: first, and: request.targetLanguage),
           let routed = request.fixedDirection(from: source.rawValue) {
            nextRequest = routed
        }
        var attempt = 1
        while true {
            let activeRequest = nextRequest
            let selectedLanguage = activeRequest.bidirectional ? nil : activeRequest.sourceLanguage?.rawValue
            progress(.pending)
            if request.bidirectional, let selectedLanguage {
                progress(.language(selectedLanguage, targetLanguage: activeRequest.targetLanguage))
            }
            do {
                let (translation, language) = try await withTimeout(configuration.requestTimeout) {
                    var language: String?
                    var text = ""
                    for try await update in translator.translate(activeRequest) {
                        switch update {
                        case .language(let code):
                            if selectedLanguage == nil {
                                language = code
                                if activeRequest.bidirectional {
                                    if let target = activeRequest.destination(for: code) {
                                        progress(.language(code, targetLanguage: target))
                                    }
                                } else {
                                    progress(.language(code))
                                }
                            }
                        case .delta(let delta):
                            text += delta
                            if !activeRequest.bidirectional || activeRequest.destination(for: language) != nil {
                                progress(.partial(text))
                            }
                        case .usage:
                            break
                        case .completed(let translation, let finalLanguage):
                            return (translation, selectedLanguage ?? finalLanguage ?? language)
                        }
                    }
                    try Task.checkCancellation()
                    throw ServiceError.invalidResponse
                }
                guard let target = activeRequest.destination(for: language) else {
                    return .unavailable(.outsideLanguagePair, error: nil)
                }
                let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return .unavailable(.unintelligible, error: nil)
                }
                if let routed = request.fixedDirection(from: language), let source = routed.sourceLanguage,
                   TranscriptLanguage.clearlyMatches(source, text: trimmed) {
                    nextRequest = routed
                    throw ServiceError.invalidResponse
                }
                return .completed(trimmed, language: language, targetLanguage: request.bidirectional ? target : nil)
            } catch {
                if Task.isCancelled { return .unavailable(.cancelled, error: nil) }
                let serviceError = error as? ServiceError
                switch serviceError {
                case .rateLimited, .quotaExceeded:
                    return .unavailable(.limitReached, error: serviceError)
                case .some(let failure) where failure.isTransient && attempt < configuration.maxAttempts:
                    attempt += 1
                    try? await Task.sleep(for: configuration.retryDelay)
                    if Task.isCancelled { return .unavailable(.cancelled, error: nil) }
                default:
                    // Includes timeouts: by then the phrase is stale, so do not retry.
                    return .unavailable(.failed, error: serviceError)
                }
            }
        }
    }
}
