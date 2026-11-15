import Foundation

// The seams between the session and the outside world. Everything that crosses
// them is a Sendable value, so each side can live in its own isolation domain.

// MARK: - Audio capture

/// 16 kHz mono signed 16-bit little-endian PCM, with its loudness.
public struct AudioChunk: Sendable, Equatable {
    public let pcm: Data
    /// Loudness of this chunk, 0 through 1.
    public let level: Float

    public init(pcm: Data, level: Float) {
        self.pcm = pcm
        self.level = level
    }
}

public enum AudioCaptureEvent: Sendable, Equatable {
    /// The system took the microphone away, for example for a phone call.
    case interruptionBegan
    /// The interruption is over. `resumed` is false when capture could not or
    /// should not restart on its own.
    case interruptionEnded(resumed: Bool)
    /// Capture stopped and cannot recover.
    case failed
}

public struct AudioCaptureStream: Sendable {
    /// Ends when capture stops. Buffering is bounded by the producer.
    public let chunks: AsyncStream<AudioChunk>
    public let events: AsyncStream<AudioCaptureEvent>

    public init(chunks: AsyncStream<AudioChunk>, events: AsyncStream<AudioCaptureEvent>) {
        self.chunks = chunks
        self.events = events
    }
}

public enum AudioCaptureError: Error, Sendable, Equatable {
    case permissionDenied
    case unavailable
}

public protocol AudioCapturing: Sendable {
    /// Asks for microphone permission if needed and starts capturing.
    /// Route and configuration changes are handled inside the implementation;
    /// the returned stream keeps delivering across them.
    func start() async throws -> AudioCaptureStream
    /// Stops capturing and releases the microphone. Safe to call when stopped.
    func stop() async
}

// MARK: - Speech to text

/// A single-use credential for one STT connection.
public struct STTCredential: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date
    public let websocketURL: URL
    public let modelID: String

    public init(accessToken: String, expiresAt: Date, websocketURL: URL, modelID: String) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.websocketURL = websocketURL
        self.modelID = modelID
    }
}

public struct STTConfiguration: Sendable, Equatable {
    public var sampleRate: Int
    /// Turn-detection tuning. Nil leaves the server default in place.
    public var endOfTurnConfidenceThreshold: Double?
    public var minEndOfTurnSilenceMilliseconds: Int?
    public var maxTurnSilenceMilliseconds: Int?

    public init(
        sampleRate: Int = 16_000,
        endOfTurnConfidenceThreshold: Double? = nil,
        minEndOfTurnSilenceMilliseconds: Int? = nil,
        maxTurnSilenceMilliseconds: Int? = nil
    ) {
        self.sampleRate = sampleRate
        self.endOfTurnConfidenceThreshold = endOfTurnConfidenceThreshold
        self.minEndOfTurnSilenceMilliseconds = minEndOfTurnSilenceMilliseconds
        self.maxTurnSilenceMilliseconds = maxTurnSilenceMilliseconds
    }
}

public enum STTEvent: Sendable, Equatable {
    /// The whole text of the current turn so far. Replaces the previous interim.
    case interim(String)
    /// The committed text of the turn. Later audio starts a new turn.
    case final(String)
    case speechStarted
    case speechStopped
    case usage(audioMilliseconds: Int)
}

/// An error frame from the STT service, in gRPC status form.
public struct STTServiceError: Error, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// The request itself is wrong; retrying the same request cannot help.
    public var isInvalidArgument: Bool { code == 3 }
    public var isAuthentication: Bool { code == 16 }
}

public enum STTConnectionError: Error, Sendable, Equatable {
    case connectFailed
    case disconnected
}

public protocol STTConnection: Sendable {
    /// Results from the service, for a single consumer. Ends when the
    /// connection closes; throws if it closed abnormally.
    var events: AsyncThrowingStream<STTEvent, Error> { get }
    func send(audio: Data) async throws
    /// Asks the service to finalize the current turn and keep listening.
    func endTurn() async throws
    /// Signals the end of audio and waits, up to `timeout`, for the service to
    /// deliver its last results and close.
    func finish(timeout: Duration) async
    /// Closes immediately, discarding anything pending.
    func cancel()
}

public protocol STTConnecting: Sendable {
    func connect(credential: STTCredential, configuration: STTConfiguration) async throws -> any STTConnection
}

// MARK: - Backend

public enum BackendError: Error, Sendable, Equatable {
    case notConfigured
    /// The backend rejected the client key.
    case unauthorized
    /// A short-term rate limit; retry after the given delay.
    case rateLimited(retryAfter: TimeInterval?)
    /// A daily quota; retrying soon will not help.
    case quotaExceeded(retryAfter: TimeInterval?)
    case server(status: Int)
    /// The request never completed: no network, timeout, connection lost.
    case transport
    case invalidResponse

    /// Whether repeating the same request might succeed.
    public var isTransient: Bool {
        switch self {
        case .server, .transport, .invalidResponse: return true
        case .notConfigured, .unauthorized, .rateLimited, .quotaExceeded: return false
        }
    }
}

public protocol CredentialProviding: Sendable {
    /// Returns a fresh credential. Credentials are single use, so this is
    /// called before every connection attempt, including reconnects.
    func sttCredential() async throws -> STTCredential
}

public struct TranslationContextItem: Sendable, Equatable, Encodable {
    public let source: String
    public let translation: String?

    public init(source: String, translation: String?) {
        self.source = source
        self.translation = translation
    }
}

public struct TranslationRequest: Sendable, Equatable {
    public let text: String
    /// Earlier phrases of the conversation, oldest first.
    public let context: [TranslationContextItem]

    public init(text: String, context: [TranslationContextItem]) {
        self.text = text
        self.context = context
    }
}

public enum TranslationUpdate: Sendable, Equatable {
    case language(String)
    /// More translated text; append it to what came before.
    case delta(String)
    case completed(translation: String, language: String?)
}

public protocol Translating: Sendable {
    /// Streams one translation. Cancelling the consumer cancels the request.
    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationUpdate, Error>
}

// MARK: - Connectivity

public protocol ConnectivityMonitoring: Sendable {
    /// Emits whether the network is usable, starting with the current state.
    func updates() -> AsyncStream<Bool>
}
