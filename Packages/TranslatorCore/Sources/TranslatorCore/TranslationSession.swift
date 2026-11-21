import Foundation

/// What the UI needs from a session.
public protocol TranslationSessionControlling: Sendable {
    /// Everything that happens, in order. Single consumer.
    var events: AsyncStream<SessionEvent> { get }
    func start(targetLanguage: TargetLanguage) async
    /// Stops listening. The microphone is released first; the last results
    /// are then collected for a bounded time. `notice` tells the user why,
    /// when the stop was not their own doing.
    func stop(notice: SessionNotice?) async
    /// Whether translations are spoken aloud. Off at first.
    func setSpeaksTranslations(_ enabled: Bool) async
}

/// Runs a listening session: microphone audio in, translated phrases out.
///
/// The actor owns all session state. Audio flows capture → pump → STT socket;
/// results flow STT socket → phrases → translation pipeline → events, and,
/// when speech is on, finished translations → speech queue → speaker. Each
/// `start()` begins a numbered run, and work belonging to an earlier run or an
/// earlier connection is ignored when it reports back.
public actor TranslationSession: TranslationSessionControlling {
    public struct Configuration: Sendable {
        public var stt = STTConfiguration()
        /// Audio kept while disconnected, to send once reconnected. Older
        /// audio is dropped first. 256,000 bytes is 8 seconds.
        public var maxPendingAudioBytes = 256_000
        public var reconnectBaseDelay: Duration = .milliseconds(500)
        public var reconnectMaxDelay: Duration = .seconds(8)
        /// Consecutive failed attempts before the session gives up.
        public var maxReconnectAttempts = 6
        /// A connection that lasted this long resets the attempt count.
        public var stableConnectionInterval: Duration = .seconds(5)
        /// Stop after this long without recognized speech. Inworld bills for
        /// audio sent, not speech detected, so an idle session costs money.
        public var idleTimeout: Duration? = .seconds(180)
        /// Ask the service to finalize a turn that has run this long, so
        /// someone speaking without pauses still gets translated.
        public var maxTurnDuration: Duration? = .seconds(15)
        /// How long Stop waits for the service to finalize the last turn.
        public var finishTimeout: Duration = .seconds(2)
        /// How long Stop waits for translations already under way.
        public var translationDrainTimeout: Duration = .seconds(6)
        /// The longest rate-limit delay the session will wait out by itself.
        public var maxRateLimitWait: Duration = .seconds(15)
        /// How often timers and waits re-check their conditions.
        public var pollInterval: Duration = .milliseconds(100)

        public init() {}
    }

    public nonisolated let events: AsyncStream<SessionEvent>

    private struct Run {
        let id: Int
        var startup: Task<Void, Never>
        var pump: Task<Void, Never>?
        var supervisor: Task<Void, Never>?
        var auxiliary: [Task<Void, Never>] = []
    }

    private let audio: any AudioCapturing
    private let connector: any STTConnecting
    private let credentials: any CredentialProviding
    private let connectivity: any ConnectivityMonitoring
    private let pipeline: TranslationPipeline
    private let speech: SpeechQueue?
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private let eventContinuation: AsyncStream<SessionEvent>.Continuation

    private var status: SessionStatus = .idle
    private var run: Run?
    private var runCounter = 0
    private var finishTask: Task<Void, Never>?
    private var translationObserver: Task<Void, Never>?
    private var speechObserver: Task<Void, Never>?

    // Phrases
    private var nextPhraseID = 1
    /// The phrase of the turn being spoken, if any.
    private var current: Phrase? {
        didSet {
            // Speech waits for a pause in the conversation.
            if (oldValue == nil) != (current == nil) {
                speech?.setFloorTaken(current != nil)
            }
        }
    }
    /// Finalized phrases whose translation has not settled.
    private var translating: [PhraseID: Phrase] = [:]

    // Speech
    private struct SpeechSlot {
        let id: PhraseID
        let language: TargetLanguage
        var settled = false
        /// What to say once settled; nil for nothing.
        var text: String?
    }

    private var speaksTranslations = false
    /// Finalized phrases, in the order they were heard, that will be spoken
    /// once settled. A phrase waits for every one before it, so each is
    /// spoken in conversation order even when translations finish out of order.
    private var speechBacklog: [SpeechSlot] = []
    private var speechFailureNoticed = false

    // Connection
    private var connection: (any STTConnection)?
    private var connectionID = 0
    private var pendingAudio: [Data] = []
    private var pendingAudioBytes = 0
    private var networkAvailable = true
    /// Bumped whenever the network comes back, to cut a backoff short.
    private var networkEpoch = 0
    private var suspended = false
    private var hasConnected = false

    // Timers
    private var lastActivity = Date.distantPast
    private var turnStartedAt: Date?
    private var endTurnRequested = false
    private var translationLimitNoticed = false

    public init(
        audio: any AudioCapturing,
        connector: any STTConnecting,
        credentials: any CredentialProviding,
        translator: any Translating,
        connectivity: any ConnectivityMonitoring,
        speech: (synthesizer: any SpeechSynthesizing, player: any SpeechPlaying)? = nil,
        configuration: Configuration = Configuration(),
        translation: TranslationPipeline.Configuration = TranslationPipeline.Configuration(),
        speechQueue: SpeechQueue.Configuration = SpeechQueue.Configuration(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.audio = audio
        self.connector = connector
        self.credentials = credentials
        self.connectivity = connectivity
        self.pipeline = TranslationPipeline(translator: translator, configuration: translation)
        self.speech = speech.map { SpeechQueue(synthesizer: $0.synthesizer, player: $0.player, configuration: speechQueue) }
        self.configuration = configuration
        self.now = now
        (events, eventContinuation) = AsyncStream<SessionEvent>.makeStream()
    }

    deinit {
        translationObserver?.cancel()
        speechObserver?.cancel()
        eventContinuation.finish()
    }

    // MARK: - Start and stop

    public func start(targetLanguage: TargetLanguage = .english) {
        guard run == nil else { return }
        observeTranslations()
        observeSpeech()
        runCounter += 1
        let id = runCounter

        // A stop still collecting its last results is cut short. The new run
        // waits for it, so capture is never started and stopped out of order.
        let previousFinish = finishTask
        finishTask = nil
        previousFinish?.cancel()

        setStatus(.starting)
        let startup = Task {
            await previousFinish?.value
            await self.startRun(id, targetLanguage: targetLanguage)
        }
        run = Run(id: id, startup: startup)
    }

    public func stop(notice: SessionNotice? = nil) async {
        if let run {
            beginStop(runID: run.id, notice: notice)
        }
        await finishTask?.value
    }

    public func setSpeaksTranslations(_ enabled: Bool) async {
        guard let speech, enabled != speaksTranslations else { return }
        speaksTranslations = enabled
        if !enabled {
            speechBacklog.removeAll()
            await speech.stop()
        }
    }

    private func isCurrent(_ runID: Int) -> Bool {
        run?.id == runID
    }

    private func startRun(_ id: Int, targetLanguage: TargetLanguage) async {
        guard isCurrent(id) else { return }
        suspended = false
        hasConnected = false
        networkAvailable = true
        translationLimitNoticed = false
        speechFailureNoticed = false
        pendingAudio.removeAll()
        pendingAudioBytes = 0
        lastActivity = now()

        let capture: AudioCaptureStream
        do {
            capture = try await audio.start()
        } catch {
            let denied = (error as? AudioCaptureError) == .permissionDenied
            beginStop(runID: id, notice: denied ? .microphoneDenied : .microphoneUnavailable)
            return
        }
        // Stopped while starting: `finish` is waiting for this task and will
        // stop the capture that was just started.
        guard isCurrent(id) else { return }

        let connectivityUpdates = connectivity.updates()
        run?.pump = Task { await self.pumpAudio(capture.chunks, runID: id) }
        run?.supervisor = Task { await self.superviseConnection(runID: id, targetLanguage: targetLanguage) }
        run?.auxiliary = [
            Task {
                for await event in capture.events {
                    self.handleCapture(event, runID: id)
                }
            },
            Task {
                for await available in connectivityUpdates {
                    self.networkChanged(available, runID: id)
                }
            },
            Task { await self.watchTimers(runID: id) },
        ]
    }

    /// Ends the run and starts its cleanup, without waiting for it. Safe to
    /// call from the run's own tasks.
    private func beginStop(runID: Int, notice: SessionNotice?) {
        guard let run, run.id == runID else { return }
        self.run = nil
        setStatus(.finishing)
        if let notice {
            emit(.notice(notice))
        }
        // Stop means quiet: nothing more is said, starting now.
        speechBacklog.removeAll()
        speech?.cancelAll()
        finishTask = Task { await self.finish(run) }
    }

    private func finish(_ run: Run) async {
        // 1. Release the microphone. Nothing network-bound comes before this.
        // Speech plays through the same audio engine, so it stops first.
        await run.startup.value
        await speech?.stop()
        await audio.stop()
        for task in run.auxiliary { task.cancel() }
        emit(.level(0))

        // 2. With capture ended, the pump sends what is left and closes the
        // stream, and the service finalizes the last turn. Give that a
        // bounded time, then tear down whatever remains.
        if connection != nil, let pump = run.pump {
            _ = await pump.value(within: configuration.finishTimeout + .milliseconds(500))
            // The socket has closed, but its last results may still be
            // buffered. The supervisor exits once it has handled them;
            // cancelling it first would drop the final transcript.
            _ = await run.supervisor?.value(within: .seconds(1))
        }
        run.pump?.cancel()
        run.supervisor?.cancel()
        connection?.cancel()
        await run.pump?.value
        await run.supervisor?.value
        connection = nil
        pendingAudio.removeAll()
        pendingAudioBytes = 0
        await commitCurrentPhrase(as: .interrupted)

        // 3. Let translations already under way finish, within a bound.
        let pipeline = self.pipeline
        let drained = await Task { await pipeline.waitUntilIdle() }
            .value(within: configuration.translationDrainTimeout) != nil
        // Cancelled means a new run has started; it shares the pipeline, so
        // leave the queue alone.
        if Task.isCancelled { return }
        if !drained {
            await pipeline.cancelAll()
        }
        if self.run == nil {
            setStatus(.idle)
        }
    }

    // MARK: - Audio out

    private func pumpAudio(_ chunks: AsyncStream<AudioChunk>, runID: Int) async {
        for await chunk in chunks {
            if isCurrent(runID), !suspended {
                emit(.level(chunk.level))
            }
            await forward(chunk.pcm)
        }
        guard !Task.isCancelled else { return }
        // Capture ended on its own, which only happens on stop. Close the
        // stream properly so the service finalizes the last turn.
        if let connection {
            _ = await sendPendingAudio(to: connection)
            await connection.finish(timeout: configuration.finishTimeout)
        }
    }

    /// Sends one chunk, or holds it while there is no connection. This is the
    /// only place audio is sent, and the pump awaits each send, so order is
    /// kept and a slow socket pushes back on the capture stream's bounded
    /// buffer instead of growing a queue here.
    private func forward(_ pcm: Data) async {
        guard !suspended else { return }
        guard let connection else {
            hold(pcm)
            return
        }
        guard await sendPendingAudio(to: connection) else {
            hold(pcm)
            return
        }
        do {
            try await connection.send(audio: pcm)
        } catch {
            // The socket is failing. Close it so the supervisor reconnects,
            // and keep the chunk for the next connection.
            hold(pcm)
            connection.cancel()
        }
    }

    /// Sends audio held while disconnected. Returns false if the socket failed.
    private func sendPendingAudio(to connection: any STTConnection) async -> Bool {
        while !pendingAudio.isEmpty {
            let chunk = pendingAudio.removeFirst()
            pendingAudioBytes -= chunk.count
            do {
                try await connection.send(audio: chunk)
            } catch {
                pendingAudio.insert(chunk, at: 0)
                pendingAudioBytes += chunk.count
                connection.cancel()
                return false
            }
        }
        return true
    }

    private func hold(_ pcm: Data) {
        pendingAudio.append(pcm)
        pendingAudioBytes += pcm.count
        while pendingAudioBytes > configuration.maxPendingAudioBytes, !pendingAudio.isEmpty {
            pendingAudioBytes -= pendingAudio.removeFirst().count
        }
    }

    // MARK: - Connection

    private enum ConnectFailure {
        case retry
        case retryAfter(Duration)
        case stop(SessionNotice)
    }

    /// Keeps one STT connection open for the life of the run, reconnecting
    /// with exponential backoff when it drops.
    private func superviseConnection(runID: Int, targetLanguage: TargetLanguage) async {
        var attempt = 0
        while isCurrent(runID), !Task.isCancelled {
            if suspended {
                attempt = 0
                try? await Task.sleep(for: configuration.pollInterval)
                continue
            }
            if !networkAvailable {
                attempt = 0
                setStatus(.waitingForNetwork)
                try? await Task.sleep(for: configuration.pollInterval)
                continue
            }
            setStatus(hasConnected ? .reconnecting : .starting)

            var delay: Duration?
            do {
                let credential = try await credentials.sttCredential()
                let connection = try await connector.connect(credential: credential, configuration: configuration.stt)
                guard isCurrent(runID), !Task.isCancelled, !suspended else {
                    connection.cancel()
                    continue
                }

                connectionID += 1
                let id = connectionID
                self.connection = connection
                hasConnected = true
                lastActivity = now()
                let connectedAt = now()
                setStatus(.listening)

                let failure = await receive(from: connection, id: id, runID: runID, targetLanguage: targetLanguage)

                if connectionID == id {
                    self.connection = nil
                }
                // Whatever was on screen for the open turn is all there will be.
                await commitCurrentPhrase(as: .interrupted, runID: runID)
                guard isCurrent(runID), !Task.isCancelled else { return }

                // The same key and the same request would be rejected again.
                if let serviceError = failure as? STTServiceError {
                    if serviceError.isAuthentication {
                        beginStop(runID: runID, notice: .unauthorized)
                        return
                    }
                    if serviceError.isInvalidArgument {
                        beginStop(runID: runID, notice: .serviceRejectedRequest)
                        return
                    }
                }
                if suspended || !networkAvailable { continue }
                if now().timeIntervalSince(connectedAt) >= configuration.stableConnectionInterval.timeInterval {
                    attempt = 0
                }
            } catch {
                guard isCurrent(runID), !Task.isCancelled else { return }
                switch classify(error) {
                case .retry:
                    break
                case .retryAfter(let wait):
                    delay = wait
                case .stop(let notice):
                    beginStop(runID: runID, notice: notice)
                    return
                }
            }

            attempt += 1
            if attempt > configuration.maxReconnectAttempts {
                beginStop(runID: runID, notice: .connectionFailed)
                return
            }
            setStatus(hasConnected ? .reconnecting : .starting)
            await backOff(delay ?? backoffDelay(attempt: attempt), runID: runID)
        }
    }

    private func classify(_ error: Error) -> ConnectFailure {
        guard let serviceError = error as? ServiceError else { return .retry }
        switch serviceError {
        case .unauthorized:
            return .stop(.unauthorized)
        case .notConfigured:
            return .stop(.notConfigured)
        case .quotaExceeded:
            return .stop(.usageLimitReached(retryAfter: nil))
        case .rateLimited(let retryAfter):
            // A short wait is absorbed; a long one is the user's to decide.
            if let retryAfter, retryAfter <= configuration.maxRateLimitWait.timeInterval {
                return .retryAfter(.milliseconds(Int(retryAfter * 1000) + 250))
            }
            return .stop(.usageLimitReached(retryAfter: retryAfter))
        case .server, .transport, .invalidResponse:
            return .retry
        }
    }

    private func backoffDelay(attempt: Int) -> Duration {
        let base = configuration.reconnectBaseDelay.timeInterval
        let ceiling = configuration.reconnectMaxDelay.timeInterval
        let exponential = min(ceiling, base * pow(2, Double(attempt - 1)))
        // Jitter keeps many clients from reconnecting in step after an outage.
        return .milliseconds(Int(exponential * Double.random(in: 0.75...1.0) * 1000))
    }

    /// Waits out a backoff, returning early if the network comes back or the
    /// run changes state.
    private func backOff(_ delay: Duration, runID: Int) async {
        let deadline = now().addingTimeInterval(delay.timeInterval)
        let epoch = networkEpoch
        while isCurrent(runID), !Task.isCancelled, !suspended, networkEpoch == epoch, now() < deadline {
            try? await Task.sleep(for: min(configuration.pollInterval, delay))
        }
    }

    /// Handles results until the connection ends. Returns the error it ended
    /// with, or nil for a clean close.
    private func receive(from connection: any STTConnection, id: Int, runID: Int, targetLanguage: TargetLanguage) async -> Error? {
        do {
            for try await event in connection.events {
                await handle(event, connectionID: id, runID: runID, targetLanguage: targetLanguage)
            }
            return nil
        } catch {
            return error
        }
    }

    private func networkChanged(_ available: Bool, runID: Int) {
        guard isCurrent(runID), available != networkAvailable else { return }
        networkAvailable = available
        if available {
            networkEpoch += 1
        } else {
            // A socket on a dead network can take a long time to notice.
            connection?.cancel()
        }
    }

    private func handleCapture(_ event: AudioCaptureEvent, runID: Int) {
        guard isCurrent(runID) else { return }
        switch event {
        case .interruptionBegan:
            guard !suspended else { return }
            suspended = true
            pendingAudio.removeAll()
            pendingAudioBytes = 0
            // Whatever was waiting to be said is stale by the time a call ends.
            speechBacklog.removeAll()
            speech?.cancelAll()
            setStatus(.interrupted)
            emit(.level(0))
            // The supervisor sees the close, commits the open phrase, and waits.
            connection?.cancel()
        case .interruptionEnded(let resumed):
            guard suspended else { return }
            if resumed {
                suspended = false
                lastActivity = now()
            } else {
                beginStop(runID: runID, notice: .stoppedByInterruption)
            }
        case .failed:
            beginStop(runID: runID, notice: .microphoneUnavailable)
        }
    }

    private func watchTimers(runID: Int) async {
        while isCurrent(runID), !Task.isCancelled {
            try? await Task.sleep(for: configuration.pollInterval)
            guard isCurrent(runID), status == .listening else { continue }
            let now = now()

            if let idleTimeout = configuration.idleTimeout,
               now.timeIntervalSince(lastActivity) > idleTimeout.timeInterval {
                beginStop(runID: runID, notice: .stoppedAfterSilence)
                return
            }
            if let maxTurnDuration = configuration.maxTurnDuration,
               let turnStartedAt, !endTurnRequested,
               now.timeIntervalSince(turnStartedAt) > maxTurnDuration.timeInterval,
               let connection {
                endTurnRequested = true
                try? await connection.endTurn()
            }
        }
    }

    // MARK: - Results in

    private func handle(_ event: STTEvent, connectionID id: Int, runID: Int, targetLanguage: TargetLanguage) async {
        // Results from a connection that has been replaced are stale.
        guard id == connectionID else { return }
        switch event {
        case .interim(let text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            lastActivity = now()
            if var phrase = current {
                guard phrase.sourceText != text else { return }
                phrase.sourceText = text
                current = phrase
                emit(.phrase(phrase))
            } else {
                let phrase = Phrase(
                    id: makePhraseID(),
                    sourceText: text,
                    targetLanguage: targetLanguage,
                    timing: PhraseTiming(startedAt: now())
                )
                current = phrase
                turnStartedAt = now()
                endTurnRequested = false
                emit(.phrase(phrase))
            }
        case .final(let text):
            lastActivity = now()
            await commit(text: text, as: .final, targetLanguage: targetLanguage, runID: runID)
        case .speechStarted, .speechStopped, .usage:
            break
        }
    }

    /// Commits the open phrase with its last provisional text, when no final
    /// result is going to arrive for it.
    private func commitCurrentPhrase(as state: Phrase.SourceState, runID: Int? = nil) async {
        guard let current else { return }
        await commit(text: current.sourceText, as: state, targetLanguage: current.targetLanguage, runID: runID)
    }

    /// Ends the current turn: the phrase becomes final and is queued for
    /// translation, exactly once.
    private func commit(text: String, as state: Phrase.SourceState, targetLanguage: TargetLanguage, runID: Int?) async {
        let existing = current
        current = nil
        turnStartedAt = nil
        endTurnRequested = false

        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.containsSpeech(text) else {
            // Noise can produce an interim that the final then retracts.
            if let existing {
                emit(.removed(existing.id))
            }
            return
        }

        let timestamp = now()
        var phrase = existing ?? Phrase(
            id: makePhraseID(),
            sourceText: text,
            targetLanguage: targetLanguage,
            timing: PhraseTiming(startedAt: timestamp)
        )
        phrase.sourceText = text
        phrase.sourceState = state
        phrase.translation = .pending
        phrase.timing.finalizedAt = timestamp
        translating[phrase.id] = phrase
        if speaksTranslations, let runID, isCurrent(runID), !suspended {
            speechBacklog.append(SpeechSlot(id: phrase.id, language: phrase.targetLanguage))
        }
        emit(.phrase(phrase))
        await pipeline.submit(id: phrase.id, text: text, targetLanguage: phrase.targetLanguage)
    }

    private func makePhraseID() -> PhraseID {
        defer { nextPhraseID += 1 }
        return PhraseID(nextPhraseID)
    }

    /// Whether the text has any letters or digits, as opposed to being empty
    /// or only punctuation.
    static func containsSpeech(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    // MARK: - Translations in

    private func observeTranslations() {
        guard translationObserver == nil else { return }
        translationObserver = Task { [weak self, updates = pipeline.updates] in
            for await update in updates {
                await self?.apply(update)
            }
        }
    }

    private func apply(_ update: TranslationPipeline.Update) {
        // A settled phrase is no longer tracked, so nothing can change it again.
        guard var phrase = translating[update.id] else { return }
        switch update.kind {
        case .pending:
            guard phrase.translation != .pending else { return }
            phrase.translation = .pending
        case .language(let code):
            phrase.languageCode = code
        case .partial(let text):
            if phrase.timing.translationStartedAt == nil {
                phrase.timing.translationStartedAt = now()
            }
            phrase.translation = .partial(text)
        case .completed(let text, let language):
            let timestamp = now()
            phrase.timing.translationStartedAt = phrase.timing.translationStartedAt ?? timestamp
            phrase.timing.translationCompletedAt = timestamp
            phrase.languageCode = language ?? phrase.languageCode
            phrase.translation = .completed(text)
        case .unavailable(let reason, let error):
            phrase.translation = .unavailable(reason)
            noteTranslationFailure(error)
        }
        translating[phrase.id] = phrase.isSettled ? nil : phrase
        emit(.phrase(phrase))
        if phrase.isSettled {
            settleSpeech(for: phrase)
        }
    }

    private func noteTranslationFailure(_ error: ServiceError?) {
        switch error {
        case .unauthorized:
            if let run {
                beginStop(runID: run.id, notice: .unauthorized)
            }
        case .rateLimited, .quotaExceeded:
            if !translationLimitNoticed {
                translationLimitNoticed = true
                emit(.notice(.translationLimited))
            }
        default:
            break
        }
    }

    // MARK: - Speech

    /// Records what a settled phrase should say, then hands the speech queue
    /// every phrase at the front of the backlog that is ready.
    private func settleSpeech(for phrase: Phrase) {
        guard let index = speechBacklog.firstIndex(where: { $0.id == phrase.id }) else { return }
        speechBacklog[index].settled = true
        speechBacklog[index].text = phrase.isSpokenInTargetLanguage ? nil : phrase.translatedText
        while let first = speechBacklog.first, first.settled {
            speechBacklog.removeFirst()
            if let text = first.text {
                speech?.enqueue(id: first.id, text: text, language: first.language)
            }
        }
    }

    private func observeSpeech() {
        guard speechObserver == nil, let speech else { return }
        speechObserver = Task { [weak self, events = speech.events] in
            for await event in events {
                await self?.apply(event)
            }
        }
    }

    private func apply(_ event: SpeechQueue.Event) {
        switch event {
        case .speaking(let id):
            // Time spent talking is not silence.
            lastActivity = now()
            emit(.speaking(id))
        case .failed:
            guard !speechFailureNoticed else { return }
            speechFailureNoticed = true
            emit(.notice(.speechUnavailable))
        }
    }

    // MARK: - Events out

    private func setStatus(_ newStatus: SessionStatus) {
        guard status != newStatus else { return }
        status = newStatus
        emit(.status(newStatus))
    }

    private func emit(_ event: SessionEvent) {
        eventContinuation.yield(event)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
