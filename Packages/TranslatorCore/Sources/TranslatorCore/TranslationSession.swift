import Foundation

/// What the UI needs from a session.
public protocol TranslationSessionControlling: Sendable {
    /// Everything that happens, in order. Single consumer.
    var events: AsyncStream<SessionEvent> { get }
    func start(sourceLanguage: TranslationLanguage?, targetLanguage: TargetLanguage, bidirectional: Bool) async
    /// Stops listening. The microphone is released first; the last results
    /// are then collected for a bounded time. `notice` tells the user why,
    /// when the stop was not their own doing.
    func stop(notice: SessionNotice?) async
    /// Whether translations are spoken aloud. Off at first.
    func setSpeaksTranslations(_ enabled: Bool) async
    /// Skips playback for earlier phrases that have yet to be spoken.
    func clearQueuedSpeech() async
}

/// Runs a listening session: microphone audio in, translated phrases out.
///
/// The actor owns all session state. Audio flows capture → pump → STT socket;
/// results flow STT socket → phrases → translation pipeline → events, and,
/// when speech is on, finished translations → speech queue → speaker. Each
/// `start()` begins a numbered run, and work belonging to an earlier run or an
/// earlier connection is ignored when it reports back.
public actor TranslationSession: TranslationSessionControlling {
    public nonisolated let events: AsyncStream<SessionEvent>

    struct Languages {
        let source: TranslationLanguage?
        let target: TargetLanguage
        let bidirectional: Bool

        var fixedSourceCode: String? { bidirectional ? nil : source?.rawValue }
    }

    struct Run {
        let id: Int
        let languages: Languages
        var startup: Task<Void, Never>
        var pump: Task<Void, Never>?
        var supervisor: Task<Void, Never>?
        var auxiliary: [Task<Void, Never>] = []
    }

    let audio: any AudioCapturing
    let connector: any STTConnecting
    let credentials: any CredentialProviding
    let connectivity: any ConnectivityMonitoring
    let pipeline: TranslationPipeline
    let speech: SpeechQueue?
    let configuration: Configuration
    let now: @Sendable () -> Date
    let eventContinuation: AsyncStream<SessionEvent>.Continuation

    var status: SessionStatus = .idle
    var run: Run?
    var runCounter = 0
    var finishTask: Task<Void, Never>?
    var translationObserver: Task<Void, Never>?
    var speechObserver: Task<Void, Never>?

    // Phrases
    var nextPhraseID = 1
    /// The phrase of the turn being spoken, if any.
    var current: Phrase? {
        didSet {
            // Speech waits for a pause in the conversation.
            if (oldValue == nil) != (current == nil) {
                speech?.setFloorTaken(current != nil)
            }
        }
    }
    /// Finalized phrases whose translation has not settled.
    var translating: [PhraseID: Phrase] = [:]

    // Speech
    struct SpeechSlot {
        let id: PhraseID
        var language: TargetLanguage
        var settled = false
        /// What to say once settled; nil for nothing.
        var text: String?
    }

    var speaksTranslations = false
    /// Finalized phrases, in the order they were heard, that will be spoken
    /// once settled. A phrase waits for every one before it, so each is
    /// spoken in conversation order even when translations finish out of order.
    var speechBacklog: [SpeechSlot] = []
    var speechFailureNoticed = false

    // Connection
    var connection: (any STTConnection)?
    var connectionID = 0
    var pendingAudio: [Data] = []
    var pendingAudioBytes = 0
    var networkAvailable = true
    /// Bumped whenever the network comes back, to cut a backoff short.
    var networkEpoch = 0
    var suspended = false
    var hasConnected = false

    // Timers
    var lastActivity = Date.distantPast
    var turnStartedAt: Date?
    var endTurnRequested = false
    var translationLimitNoticed = false

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

    public func start(
        sourceLanguage: TranslationLanguage? = nil,
        targetLanguage: TargetLanguage = .english,
        bidirectional: Bool = false
    ) {
        guard run == nil else { return }
        observeTranslations()
        observeSpeech()
        runCounter += 1
        let id = runCounter
        let languages = Languages(
            source: sourceLanguage,
            target: targetLanguage,
            bidirectional: bidirectional && sourceLanguage != nil && sourceLanguage != targetLanguage
        )

        // A stop still collecting its last results is cut short. The new run
        // waits for it, so capture is never started and stopped out of order.
        let previousFinish = finishTask
        finishTask = nil
        previousFinish?.cancel()

        setStatus(.starting)
        let startup = Task {
            await previousFinish?.value
            await self.startRun(id)
        }
        run = Run(id: id, languages: languages, startup: startup)
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

    public func clearQueuedSpeech() {
        // Ignore earlier phrases even if their translations arrive after the
        // queue is cleared. They still finish as captions.
        speechBacklog.removeAll()
        speech?.clearWaiting()
    }

    func isCurrent(_ runID: Int) -> Bool {
        run?.id == runID
    }

    func startRun(_ id: Int) async {
        guard let languages = run?.languages, isCurrent(id) else { return }
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
        run?.supervisor = Task { await self.superviseConnection(runID: id, languages: languages) }
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
    func beginStop(runID: Int, notice: SessionNotice?) {
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

    func finish(_ run: Run) async {
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
        await commitCurrentPhrase(as: .interrupted, languages: run.languages)

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
}
