import Foundation
import TranslatorCore

/// What the translation screen shows, kept on the main actor. Consumes the
/// session's events and holds the conversation shown on screen.
@MainActor
final class TranslationViewModel {
    enum TranscriptContent {
        case original
        case translation
        case both
    }

    /// Older phrases are dropped past this, so a long session stays bounded.
    nonisolated static let maxPhrases = 2000
    static let speaksTranslationsKey = "SpeaksTranslations"
    private static let minimumSpeechQueueDepthForJump = 5
    static let sourceLanguageKey = "SourceLanguage"
    static let targetLanguageKey = "TargetLanguage"
    static let bidirectionalKey = "BidirectionalTranslation"

    var onPhrasesChanged: ((PhraseChanges) -> Void)?
    var onStatusChanged: ((SessionStatus) -> Void)?
    var onLevelChanged: ((Float) -> Void)?
    var onNoticeChanged: ((Notice?) -> Void)?
    /// A translation was completed, for VoiceOver to read out.
    var onTranslationCompleted: ((Phrase) -> Void)?
    var onSpeakingChanged: ((PhraseID?) -> Void)?
    var onSpeaksTranslationsChanged: ((Bool) -> Void)?
    var onSpeechQueueChanged: (() -> Void)?
    var onLanguagesChanged: (() -> Void)?

    private(set) var phrases: [Phrase] = []
    private(set) var status: SessionStatus = .idle
    private(set) var notice: Notice?
    /// The phrase whose translation is being spoken aloud.
    private(set) var speaking: PhraseID?
    /// Whether translations are spoken aloud. Remembered between launches.
    private(set) var speaksTranslations: Bool
    private var speechQueueDepth = 0
    private var isClearingSpeechQueue = false
    private(set) var sourceLanguage: TranslationLanguage?
    private(set) var targetLanguage: TargetLanguage
    private var prefersBidirectional: Bool

    private let session: any TranslationSessionControlling
    private let defaults: UserDefaults
    private let hasAPIKey: @MainActor () -> Bool
    private var positions: [PhraseID: Int] = [:]
    private var events: Task<Void, Never>?

    init(session: any TranslationSessionControlling, defaults: UserDefaults = .standard, hasAPIKey: @escaping @MainActor () -> Bool) {
        self.session = session
        self.defaults = defaults
        self.hasAPIKey = hasAPIKey
        speaksTranslations = defaults.bool(forKey: Self.speaksTranslationsKey)
        sourceLanguage = defaults.string(forKey: Self.sourceLanguageKey).flatMap(TranslationLanguage.init(rawValue:))
        targetLanguage = defaults.string(forKey: Self.targetLanguageKey).flatMap(TargetLanguage.init(rawValue:)) ?? .english
        prefersBidirectional = defaults.bool(forKey: Self.bidirectionalKey)
        events = Task { [weak self, events = session.events] in
            for await event in events {
                self?.apply(event)
            }
        }
        if speaksTranslations {
            Task { [session] in await session.setSpeaksTranslations(true) }
        }
    }

    deinit {
        events?.cancel()
    }

    var isRunning: Bool { status.isRunning }
    var canChangeLanguages: Bool { status == .idle }
    var canUseBidirectional: Bool { sourceLanguage != nil && sourceLanguage != targetLanguage }
    var isBidirectional: Bool { canUseBidirectional && prefersBidirectional }
    var canJumpToLatestSpeech: Bool {
        speaksTranslations && isRunning && !isClearingSpeechQueue
            && speechQueueDepth >= Self.minimumSpeechQueueDepthForJump
    }

    func phrase(for id: PhraseID) -> Phrase? {
        positions[id].map { phrases[$0] }
    }

    // MARK: Actions

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isRunning else { return }
        guard hasAPIKey() else {
            show(Notice(message: String(localized: "Add your Inworld API key to start translating."), action: .openAPIKeySettings))
            return
        }
        show(nil)
        let sourceLanguage = self.sourceLanguage
        let targetLanguage = self.targetLanguage
        let bidirectional = isBidirectional
        apply(.status(.starting))
        Task {
            await session.start(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, bidirectional: bidirectional)
        }
    }

    func stop(notice: SessionNotice? = nil) {
        Task { await session.stop(notice: notice) }
    }

    func dismissNotice() {
        show(nil)
    }

    func setSpeaksTranslations(_ enabled: Bool) {
        guard enabled != speaksTranslations else { return }
        speaksTranslations = enabled
        defaults.set(enabled, forKey: Self.speaksTranslationsKey)
        onSpeaksTranslationsChanged?(enabled)
        Task { [session] in await session.setSpeaksTranslations(enabled) }
    }

    func jumpToLatestSpeech() {
        guard canJumpToLatestSpeech else { return }
        isClearingSpeechQueue = true
        onSpeechQueueChanged?()
        Task { [session] in await session.clearQueuedSpeech() }
    }

    func setSourceLanguage(_ language: TranslationLanguage?) {
        guard canChangeLanguages, sourceLanguage != language else { return }
        sourceLanguage = language
        defaults.set(language?.rawValue, forKey: Self.sourceLanguageKey)
        onLanguagesChanged?()
    }

    func setTargetLanguage(_ language: TargetLanguage) {
        guard canChangeLanguages, targetLanguage != language else { return }
        targetLanguage = language
        defaults.set(language.rawValue, forKey: Self.targetLanguageKey)
        onLanguagesChanged?()
    }

    func toggleBidirectional() {
        guard canChangeLanguages, canUseBidirectional else { return }
        prefersBidirectional.toggle()
        defaults.set(prefersBidirectional, forKey: Self.bidirectionalKey)
        onLanguagesChanged?()
    }

    /// A notice asking for a key is out of date once the key changes.
    func apiKeyChanged() {
        guard notice?.action == .openAPIKeySettings else { return }
        show(nil)
    }

    func clear() {
        let removed = phrases.filter(\.isSettled).map(\.id)
        guard !removed.isEmpty else { return }
        let keep = phrases.filter { !$0.isSettled }
        phrases = keep
        reindex()
        onPhrasesChanged?(PhraseChanges(removed: removed))
    }

    func replaceConversation(with archive: ConversationArchive) -> Bool {
        guard status == .idle else { return false }
        let previous = phrases.map(\.id)
        let previousIDs = Set(previous)
        phrases = archive.restoredPhrases()
        reindex()
        let current = phrases.map(\.id)
        onPhrasesChanged?(PhraseChanges(
            inserted: current.filter { !previousIDs.contains($0) },
            updated: current.filter(previousIDs.contains),
            removed: previous.filter { positions[$0] == nil }
        ))
        return true
    }

    /// The whole conversation as text, for copying.
    func transcript(_ content: TranscriptContent) -> String {
        phrases
            .filter { $0.sourceState != .provisional }
            .compactMap { phrase in
                switch content {
                case .original: phrase.sourceText
                case .translation: phrase.isSpokenInTargetLanguage ? nil : phrase.translatedText
                case .both: Self.text(for: phrase)
                }
            }
            .joined(separator: "\n\n")
    }

    static func text(for phrase: Phrase) -> String {
        guard let translation = phrase.translatedText, !phrase.isSpokenInTargetLanguage else { return phrase.sourceText }
        return "\(phrase.sourceText)\n\(translation)"
    }

    // MARK: Events

    func apply(_ event: SessionEvent) {
        switch event {
        case .status(let newStatus):
            guard status != newStatus else { return }
            status = newStatus
            onStatusChanged?(newStatus)
        case .level(let level):
            onLevelChanged?(level)
        case .notice(let sessionNotice):
            show(Self.notice(for: sessionNotice))
        case .phrase(let phrase):
            upsert(phrase)
        case .removed(let id):
            guard let index = positions[id] else { return }
            phrases.remove(at: index)
            reindex()
            onPhrasesChanged?(PhraseChanges(removed: [id]))
        case .speaking(let id):
            guard id != speaking else { return }
            let previous = speaking
            speaking = id
            onSpeakingChanged?(id)
            // The phrases that started and stopped being spoken show it.
            let changed = [previous, id].compactMap { $0 }.filter { positions[$0] != nil }
            if !changed.isEmpty {
                onPhrasesChanged?(PhraseChanges(updated: changed))
            }
        case .speechQueueDepth(let count):
            speechQueueDepth = count
            if count == 0 { isClearingSpeechQueue = false }
            onSpeechQueueChanged?()
        }
    }

    private func upsert(_ phrase: Phrase) {
        if let index = positions[phrase.id] {
            let wasCompleted = phrases[index].translatedText != nil
            phrases[index] = phrase
            onPhrasesChanged?(PhraseChanges(updated: [phrase.id]))
            if !wasCompleted, phrase.translatedText != nil {
                onTranslationCompleted?(phrase)
            }
            return
        }
        var changes = PhraseChanges()
        // IDs grow in the order phrases were heard, so new ones nearly always
        // go at the end; insert in order regardless.
        let index = phrases.lastIndex { $0.id < phrase.id }.map { $0 + 1 } ?? 0
        phrases.insert(phrase, at: index)
        changes.inserted = [phrase.id]
        if phrases.count > Self.maxPhrases {
            let overflow = phrases.prefix(phrases.count - Self.maxPhrases)
            changes.removed = overflow.map(\.id)
            phrases.removeFirst(overflow.count)
        }
        reindex()
        onPhrasesChanged?(changes)
    }

    private func reindex() {
        positions = Dictionary(uniqueKeysWithValues: phrases.enumerated().map { ($1.id, $0) })
    }

    private func show(_ newNotice: Notice?) {
        guard notice != newNotice else { return }
        notice = newNotice
        onNoticeChanged?(newNotice)
    }
}
