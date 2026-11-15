import Foundation
import Synchronization
@testable import TranslatorCore

// Test doubles for every dependency of `TranslationSession`. Each records what
// was asked of it and can be steered from the test.

struct TestTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` until it holds, failing after `timeout`.
func eventually(
    _ what: String,
    timeout: Duration = .seconds(3),
    _ condition: @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TestTimeout(description: "Timed out waiting for: \(what)")
}

// MARK: - Audio

final class FakeAudio: AudioCapturing {
    struct State {
        var starts = 0
        var stops = 0
        var capturing = false
        var chunks: AsyncStream<AudioChunk>.Continuation?
        var events: AsyncStream<AudioCaptureEvent>.Continuation?
        var startError: AudioCaptureError?
        var startDelay: Duration?
    }

    let state = Mutex(State())

    var isCapturing: Bool { state.withLock { $0.capturing } }
    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }

    func failNextStart(_ error: AudioCaptureError) {
        state.withLock { $0.startError = error }
    }

    func delayStarts(_ delay: Duration) {
        state.withLock { $0.startDelay = delay }
    }

    func start() async throws -> AudioCaptureStream {
        if let delay = state.withLock({ $0.startDelay }) {
            try? await Task.sleep(for: delay)
        }
        let (chunks, chunkContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (events, eventContinuation) = AsyncStream<AudioCaptureEvent>.makeStream()
        try state.withLock { state in
            state.starts += 1
            if let error = state.startError {
                state.startError = nil
                throw error
            }
            state.capturing = true
            state.chunks = chunkContinuation
            state.events = eventContinuation
        }
        return AudioCaptureStream(chunks: chunks, events: events)
    }

    func stop() async {
        let (chunks, events) = state.withLock { state in
            state.stops += 1
            state.capturing = false
            defer {
                state.chunks = nil
                state.events = nil
            }
            return (state.chunks, state.events)
        }
        chunks?.finish()
        events?.finish()
    }

    /// Delivers one chunk; the bytes are `marker` repeated.
    func speak(_ marker: UInt8, bytes: Int = 320, level: Float = 0.5) {
        _ = state.withLock { $0.chunks }?.yield(AudioChunk(pcm: Data(repeating: marker, count: bytes), level: level))
    }

    func send(_ event: AudioCaptureEvent) {
        state.withLock { $0.events }?.yield(event)
    }
}

// MARK: - STT

final class FakeSTTConnection: STTConnection {
    struct State {
        var audio: [Data] = []
        var endTurns = 0
        var finishRequested = false
        var cancelled = false
        /// The service or the network closed the socket; sends now fail.
        var closed = false
        var sendError: Error?
    }

    let events: AsyncThrowingStream<STTEvent, Error>
    let index: Int
    let credential: STTCredential
    private let continuation: AsyncThrowingStream<STTEvent, Error>.Continuation
    /// What the service sends after closeStream, before it closes.
    private let finalResults: @Sendable () -> [STTEvent]
    let state = Mutex(State())

    init(index: Int, credential: STTCredential, finalResults: @escaping @Sendable () -> [STTEvent]) {
        self.index = index
        self.credential = credential
        self.finalResults = finalResults
        (events, continuation) = AsyncThrowingStream<STTEvent, Error>.makeStream()
    }

    var audio: [Data] { state.withLock { $0.audio } }
    var audioMarkers: [UInt8] { audio.compactMap(\.first) }
    var finishRequested: Bool { state.withLock { $0.finishRequested } }
    var isCancelled: Bool { state.withLock { $0.cancelled } }
    var endTurns: Int { state.withLock { $0.endTurns } }

    func send(audio: Data) async throws {
        try state.withLock { state in
            if let error = state.sendError { throw error }
            if state.cancelled || state.closed { throw STTConnectionError.disconnected }
            state.audio.append(audio)
        }
    }

    func endTurn() async throws {
        state.withLock { $0.endTurns += 1 }
    }

    func finish(timeout: Duration) async {
        state.withLock { $0.finishRequested = true }
        for event in finalResults() {
            continuation.yield(event)
        }
        continuation.finish()
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
        continuation.finish(throwing: STTConnectionError.disconnected)
    }

    // Driving the service side.

    func emit(_ event: STTEvent) {
        continuation.yield(event)
    }

    func interim(_ text: String) {
        emit(.interim(text))
    }

    func final(_ text: String) {
        emit(.final(text))
    }

    /// The service closes the connection with an error frame.
    func fail(_ error: Error) {
        state.withLock { $0.closed = true }
        continuation.finish(throwing: error)
    }

    /// The network drops the connection.
    func drop() {
        state.withLock { $0.closed = true }
        continuation.finish(throwing: STTConnectionError.disconnected)
    }
}

final class FakeSTTConnector: STTConnecting {
    struct State {
        var connections: [FakeSTTConnection] = []
        var failures: [Error] = []
        var finalResults: [STTEvent] = []
        var configurations: [STTConfiguration] = []
    }

    let state = Mutex(State())

    var connections: [FakeSTTConnection] { state.withLock { $0.connections } }
    var latest: FakeSTTConnection? { connections.last }
    var count: Int { connections.count }

    /// Makes the next connection attempts fail, in order.
    func failNext(_ errors: Error...) {
        state.withLock { $0.failures.append(contentsOf: errors) }
    }

    /// What every connection sends after closeStream.
    func onFinish(_ events: [STTEvent]) {
        state.withLock { $0.finalResults = events }
    }

    func connect(credential: STTCredential, configuration: STTConfiguration) async throws -> any STTConnection {
        try state.withLock { state in
            state.configurations.append(configuration)
            if !state.failures.isEmpty { throw state.failures.removeFirst() }
            let connection = FakeSTTConnection(
                index: state.connections.count,
                credential: credential,
                finalResults: { [weak self] in self?.state.withLock { $0.finalResults } ?? [] }
            )
            state.connections.append(connection)
            return connection
        }
    }

    /// Waits for connection number `index` (zero-based) to be opened.
    func connection(_ index: Int) async throws -> FakeSTTConnection {
        try await eventually("STT connection \(index)") { self.count > index }
        return connections[index]
    }
}

final class FakeCredentials: CredentialProviding {
    struct State {
        var issued: [STTCredential] = []
        var failures: [Error] = []
    }

    let state = Mutex(State())

    var issued: [STTCredential] { state.withLock { $0.issued } }

    func failNext(_ errors: Error...) {
        state.withLock { $0.failures.append(contentsOf: errors) }
    }

    func sttCredential() async throws -> STTCredential {
        try state.withLock { state in
            if !state.failures.isEmpty { throw state.failures.removeFirst() }
            let credential = STTCredential(
                accessToken: "token-\(state.issued.count)",
                expiresAt: Date().addingTimeInterval(120),
                websocketURL: URL(string: "wss://stt.invalid/stream")!,
                modelID: "inworld/inworld-stt-1"
            )
            state.issued.append(credential)
            return credential
        }
    }
}

// MARK: - Translation

/// Each request waits until the test answers it, unless `autoReply` is set.
final class FakeTranslator: Translating {
    final class Call: Sendable {
        let request: TranslationRequest
        let continuation: AsyncThrowingStream<TranslationUpdate, Error>.Continuation
        let cancelled = Mutex(false)

        init(request: TranslationRequest, continuation: AsyncThrowingStream<TranslationUpdate, Error>.Continuation) {
            self.request = request
            self.continuation = continuation
        }

        var isCancelled: Bool { cancelled.withLock { $0 } }

        func reply(_ translation: String, language: String? = nil, chunks: Int = 1) {
            if let language { continuation.yield(.language(language)) }
            let words = translation.split(separator: " ", omittingEmptySubsequences: false)
            let size = max(1, (words.count + chunks - 1) / chunks)
            var index = 0
            while index < words.count {
                let piece = words[index..<min(words.count, index + size)].joined(separator: " ")
                continuation.yield(.delta(index == 0 ? piece : " " + piece))
                index += size
            }
            continuation.yield(.completed(translation: translation, language: language))
            continuation.finish()
        }

        func partial(_ text: String) {
            continuation.yield(.delta(text))
        }

        func fail(_ error: Error) {
            continuation.finish(throwing: error)
        }
    }

    struct State {
        var calls: [Call] = []
        var autoReply: (@Sendable (TranslationRequest) -> (String, String?))?
    }

    let state = Mutex(State())

    var calls: [Call] { state.withLock { $0.calls } }
    var requests: [TranslationRequest] { calls.map(\.request) }

    /// Answers every request immediately.
    func autoReply(_ reply: @escaping @Sendable (TranslationRequest) -> (String, String?)) {
        state.withLock { $0.autoReply = reply }
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationUpdate, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranslationUpdate, Error>.makeStream()
        let call = Call(request: request, continuation: continuation)
        continuation.onTermination = { termination in
            if case .cancelled = termination { call.cancelled.withLock { $0 = true } }
        }
        let autoReply = state.withLock { state in
            state.calls.append(call)
            return state.autoReply
        }
        if let autoReply {
            let (text, language) = autoReply(request)
            call.reply(text, language: language)
        }
        return stream
    }

    /// Waits for request number `index` (zero-based).
    func call(_ index: Int) async throws -> Call {
        try await eventually("translation request \(index)") { self.calls.count > index }
        return calls[index]
    }
}

// MARK: - Connectivity

final class FakeConnectivity: ConnectivityMonitoring {
    let continuations = Mutex<[AsyncStream<Bool>.Continuation]>([])
    let current = Mutex(true)

    func updates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        continuation.yield(current.withLock { $0 })
        continuations.withLock { $0.append(continuation) }
        return stream
    }

    func set(_ available: Bool) {
        current.withLock { $0 = available }
        for continuation in continuations.withLock({ $0 }) {
            continuation.yield(available)
        }
    }
}

// MARK: - Session harness

final class EventLog: Sendable {
    let events = Mutex<[SessionEvent]>([])
}

/// A session wired to fakes, with every event it emits recorded.
final class SessionHarness: Sendable {
    let audio = FakeAudio()
    let stt = FakeSTTConnector()
    let credentials = FakeCredentials()
    let translator = FakeTranslator()
    let connectivity = FakeConnectivity()
    let session: TranslationSession
    private let recorded = EventLog()
    private let recorder: Task<Void, Never>

    init(
        configure: (inout TranslationSession.Configuration) -> Void = { _ in },
        translation: (inout TranslationPipeline.Configuration) -> Void = { _ in }
    ) {
        var configuration = TranslationSession.Configuration()
        configuration.reconnectBaseDelay = .milliseconds(10)
        configuration.reconnectMaxDelay = .milliseconds(40)
        configuration.pollInterval = .milliseconds(5)
        configuration.finishTimeout = .milliseconds(300)
        configuration.translationDrainTimeout = .milliseconds(300)
        configuration.idleTimeout = nil
        configuration.maxTurnDuration = nil
        configure(&configuration)

        var pipeline = TranslationPipeline.Configuration()
        pipeline.requestTimeout = .seconds(2)
        pipeline.retryDelay = .milliseconds(10)
        translation(&pipeline)

        session = TranslationSession(
            audio: audio,
            connector: stt,
            credentials: credentials,
            translator: translator,
            connectivity: connectivity,
            configuration: configuration,
            translation: pipeline
        )
        let events = session.events
        let recorded = self.recorded
        recorder = Task {
            for await event in events {
                recorded.events.withLock { $0.append(event) }
            }
        }
    }

    deinit {
        recorder.cancel()
    }

    var events: [SessionEvent] { recorded.events.withLock { $0 } }

    var statuses: [SessionStatus] {
        events.compactMap { if case .status(let status) = $0 { status } else { nil } }
    }

    var notices: [SessionNotice] {
        events.compactMap { if case .notice(let notice) = $0 { notice } else { nil } }
    }

    var status: SessionStatus? { statuses.last }

    /// The latest version of every phrase, in ID order, without removed ones.
    var phrases: [Phrase] {
        var latest: [PhraseID: Phrase] = [:]
        for event in events {
            switch event {
            case .phrase(let phrase): latest[phrase.id] = phrase
            case .removed(let id): latest[id] = nil
            default: break
            }
        }
        return latest.values.sorted { $0.id < $1.id }
    }

    /// Every version a phrase went through, in order.
    func history(of id: PhraseID) -> [Phrase] {
        events.compactMap { if case .phrase(let phrase) = $0, phrase.id == id { phrase } else { nil } }
    }

    func waitForStatus(_ status: SessionStatus, timeout: Duration = .seconds(3)) async throws {
        try await eventually("status \(status)", timeout: timeout) { self.status == status }
    }

    func waitForPhrases(_ what: String, _ condition: @escaping @Sendable ([Phrase]) -> Bool) async throws {
        try await eventually(what) { condition(self.phrases) }
    }

    /// Starts the session and waits for the first connection to be listening.
    @discardableResult
    func startListening() async throws -> FakeSTTConnection {
        await session.start()
        let connection = try await stt.connection(0)
        try await waitForStatus(.listening)
        return connection
    }
}
