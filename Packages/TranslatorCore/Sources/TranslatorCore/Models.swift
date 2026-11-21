import Foundation

/// Identifies one phrase for the lifetime of the app. IDs increase in the
/// order phrases were first heard, so sorting by ID is sorting by time.
public struct PhraseID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: PhraseID, rhs: PhraseID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "#\(rawValue)" }
}

/// Why a finalized phrase has no translation.
public enum TranslationUnavailableReason: String, Codable, Sendable, Equatable {
    /// The request failed, or timed out, after any retry.
    case failed
    /// Dropped from the queue so translation could keep up with live speech.
    case skipped
    /// The session stopped before the translation finished.
    case cancelled
    /// Nothing translatable was recognized in the audio.
    case unintelligible
    /// No direction could be selected for a two-way translation.
    case outsideLanguagePair
    /// Inworld refused the request because a usage limit was reached.
    case limitReached
}

/// When each stage of a phrase happened, for latency measurement.
public struct PhraseTiming: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var finalizedAt: Date?
    public var translationStartedAt: Date?
    public var translationCompletedAt: Date?

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// Time from the final transcript to the first translated text.
    public var firstTextLatency: TimeInterval? {
        guard let finalizedAt, let translationStartedAt else { return nil }
        return translationStartedAt.timeIntervalSince(finalizedAt)
    }

    /// Time from the final transcript to the complete translation.
    public var translationLatency: TimeInterval? {
        guard let finalizedAt, let translationCompletedAt else { return nil }
        return translationCompletedAt.timeIntervalSince(finalizedAt)
    }
}

/// One spoken phrase: the recognized source text and its translation.
public struct Phrase: Identifiable, Sendable, Equatable {
    public enum SourceState: Sendable, Equatable {
        /// Still being spoken; the text is replaced as recognition improves.
        case provisional
        /// The recognizer committed this text.
        case final
        /// Committed from the last provisional text because the connection or
        /// the session ended before the recognizer finalized the turn.
        case interrupted
    }

    public enum Translation: Sendable, Equatable {
        /// Not requested yet; the source is still provisional.
        case none
        /// Requested, no text yet.
        case pending
        /// Text received so far; more is coming.
        case partial(String)
        case completed(String)
        case unavailable(TranslationUnavailableReason)
    }

    public let id: PhraseID
    public var sourceText: String
    public var sourceState: SourceState
    public var translation: Translation
    /// Selected or detected ISO 639 code of the source language.
    public var languageCode: String?
    public internal(set) var targetLanguage: TargetLanguage
    public var timing: PhraseTiming

    public init(
        id: PhraseID,
        sourceText: String,
        sourceState: SourceState = .provisional,
        translation: Translation = .none,
        languageCode: String? = nil,
        targetLanguage: TargetLanguage = .english,
        timing: PhraseTiming
    ) {
        self.id = id
        self.sourceText = sourceText
        self.sourceState = sourceState
        self.translation = translation
        self.languageCode = languageCode
        self.targetLanguage = targetLanguage
        self.timing = timing
    }

    /// The finished translation, if there is one.
    public var translatedText: String? {
        if case .completed(let text) = translation { return text }
        return nil
    }

    /// The finished translation for consumers that expect English.
    public var english: String? {
        targetLanguage == .english ? translatedText : nil
    }

    public var isSpokenInEnglish: Bool {
        TargetLanguage.english.matches(languageCode)
    }

    /// True when the translation would repeat the source.
    public var isSpokenInTargetLanguage: Bool {
        targetLanguage.matches(languageCode)
    }

    /// True once neither the source nor the translation can change again.
    public var isSettled: Bool {
        switch translation {
        case .completed, .unavailable: return true
        case .none, .pending, .partial: return false
        }
    }
}

public enum SessionStatus: Sendable, Equatable {
    case idle
    /// Getting microphone access and opening the first connection.
    case starting
    case listening
    /// The connection dropped; a new one is being opened.
    case reconnecting
    case waitingForNetwork
    /// Another app, such as a phone call, has taken the microphone.
    case interrupted
    /// Stop was requested; the microphone is off and the last results are
    /// being collected.
    case finishing

    /// True while the session holds, or is about to hold, the microphone.
    public var isRunning: Bool {
        switch self {
        case .idle, .finishing: return false
        case .starting, .listening, .reconnecting, .waitingForNetwork, .interrupted: return true
        }
    }
}

/// Something the user should be told about why the session ended or degraded.
public enum SessionNotice: Sendable, Equatable {
    case microphoneDenied
    case microphoneUnavailable
    /// No API key has been saved.
    case notConfigured
    /// Inworld rejected the API key.
    case unauthorized
    case usageLimitReached(retryAfter: TimeInterval?)
    case connectionFailed
    case serviceRejectedRequest
    case stoppedAfterSilence
    case stoppedInBackground
    case stoppedByInterruption
    /// Translations are being refused by a usage limit; listening continues.
    case translationLimited
    /// The translation could not be spoken aloud; captions continue.
    case speechUnavailable
}

public enum SessionEvent: Sendable, Equatable {
    case status(SessionStatus)
    /// A phrase was added or changed. Match on `phrase.id`.
    case phrase(Phrase)
    /// A provisional phrase turned out to contain no speech.
    case removed(PhraseID)
    /// Microphone level, 0 through 1.
    case level(Float)
    case notice(SessionNotice)
    /// This phrase's translation is being spoken aloud; nil once nothing is.
    /// Listening is paused meanwhile, so the phone does not hear itself.
    case speaking(PhraseID?)
}
