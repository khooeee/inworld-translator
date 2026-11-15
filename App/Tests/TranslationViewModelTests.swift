import Foundation
import Synchronization
import Testing
import TranslatorCore
@testable import InworldTranslator

/// Records what the view model asks of the session, and lets a test send
/// session events.
final class FakeSession: TranslationSessionControlling {
    enum Call: Equatable {
        case start
        case stop(SessionNotice?)
    }

    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let recorded = Mutex<[Call]>([])

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func send(_ event: SessionEvent) {
        continuation.yield(event)
    }

    func start() async {
        recorded.withLock { $0.append(.start) }
    }

    func stop(notice: SessionNotice?) async {
        recorded.withLock { $0.append(.stop(notice)) }
    }
}

@MainActor
@Suite struct TranslationViewModelTests {
    let session = FakeSession()

    func makeModel(hasKey: Bool = true) -> TranslationViewModel {
        TranslationViewModel(session: session) { hasKey }
    }

    func phrase(
        _ id: Int,
        _ text: String = "hola",
        state: Phrase.SourceState = .final,
        translation: Phrase.Translation = .pending,
        language: String? = "es"
    ) -> Phrase {
        Phrase(id: PhraseID(id), sourceText: text, sourceState: state, translation: translation, languageCode: language, timing: PhraseTiming(startedAt: .now))
    }

    /// Waits for work the view model started in a task.
    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Start and stop

    @Test func startWithoutKeyAsksForOneAndDoesNotStart() async {
        let model = makeModel(hasKey: false)
        var shown: [TranslationViewModel.Notice?] = []
        model.onNoticeChanged = { shown.append($0) }

        model.start()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.notice?.action == .openAPIKeySettings)
        #expect(shown.count == 1)
        #expect(session.calls.isEmpty)
    }

    @Test func startWithKeyClearsNoticeAndStartsSession() async {
        let model = makeModel()
        model.apply(.notice(.connectionFailed))

        model.start()
        await eventually { session.calls == [.start] }

        #expect(model.notice == nil)
        #expect(session.calls == [.start])
    }

    @Test func toggleStopsWhileRunning() async {
        let model = makeModel()
        model.apply(.status(.listening))

        model.toggle()
        await eventually { !session.calls.isEmpty }

        #expect(session.calls == [.stop(nil)])
    }

    @Test func savingAKeyClearsOnlyKeyNotices() {
        let model = makeModel()
        model.apply(.notice(.unauthorized))
        model.apiKeyChanged()
        #expect(model.notice == nil)

        model.apply(.notice(.stoppedInBackground))
        model.apiKeyChanged()
        #expect(model.notice != nil)
    }

    // MARK: Session events

    @Test func eventsFromTheSessionReachTheScreen() async {
        let model = makeModel()
        var statuses: [SessionStatus] = []
        model.onStatusChanged = { statuses.append($0) }

        session.send(.status(.starting))
        session.send(.status(.listening))
        session.send(.phrase(phrase(1)))
        await eventually { model.phrases.count == 1 }

        #expect(statuses == [.starting, .listening])
        #expect(model.isRunning)
        #expect(model.phrases.map(\.id) == [PhraseID(1)])
    }

    @Test func revisionsUpdateInPlace() {
        let model = makeModel()
        var changes: [TranslationViewModel.PhraseChanges] = []
        model.onPhrasesChanged = { changes.append($0) }

        model.apply(.phrase(phrase(1, "ho", state: .provisional, translation: .none)))
        model.apply(.phrase(phrase(1, "hola", state: .provisional, translation: .none)))
        model.apply(.phrase(phrase(1, "Hola.")))

        #expect(model.phrases.count == 1)
        #expect(model.phrases[0].sourceText == "Hola.")
        #expect(changes == [
            .init(inserted: [PhraseID(1)]),
            .init(updated: [PhraseID(1)]),
            .init(updated: [PhraseID(1)]),
        ])
    }

    @Test func phrasesStayInSpokenOrder() {
        let model = makeModel()
        model.apply(.phrase(phrase(3)))
        model.apply(.phrase(phrase(1)))
        model.apply(.phrase(phrase(2)))

        #expect(model.phrases.map(\.id.rawValue) == [1, 2, 3])
        #expect(model.phrase(for: PhraseID(2))?.id == PhraseID(2))
    }

    @Test func completedTranslationIsAnnouncedOnce() {
        let model = makeModel()
        var announced: [String] = []
        model.onTranslationCompleted = { announced.append($0.english ?? "") }

        model.apply(.phrase(phrase(1)))
        model.apply(.phrase(phrase(1, translation: .partial("Hel"))))
        model.apply(.phrase(phrase(1, translation: .completed("Hello."))))
        model.apply(.phrase(phrase(1, translation: .completed("Hello."))))

        #expect(announced == ["Hello."])
    }

    @Test func removedPhraseIsDropped() {
        let model = makeModel()
        model.apply(.phrase(phrase(1)))
        model.apply(.phrase(phrase(2)))
        model.apply(.removed(PhraseID(1)))
        model.apply(.removed(PhraseID(9)))

        #expect(model.phrases.map(\.id.rawValue) == [2])
        #expect(model.phrase(for: PhraseID(1)) == nil)
    }

    @Test func historyIsBounded() {
        let model = makeModel()
        var last = TranslationViewModel.PhraseChanges()
        model.onPhrasesChanged = { last = $0 }

        for id in 1...(TranslationViewModel.maxPhrases + 1) {
            model.apply(.phrase(phrase(id)))
        }

        #expect(model.phrases.count == TranslationViewModel.maxPhrases)
        #expect(model.phrases.first?.id == PhraseID(2))
        #expect(last.removed == [PhraseID(1)])
        #expect(model.phrase(for: PhraseID(1)) == nil)
    }

    // MARK: Clear and copy

    @Test func clearKeepsPhrasesStillInProgress() {
        let model = makeModel()
        model.apply(.phrase(phrase(1, translation: .completed("Hello."))))
        model.apply(.phrase(phrase(2, translation: .unavailable(.failed))))
        model.apply(.phrase(phrase(3, translation: .pending)))
        model.apply(.phrase(phrase(4, state: .provisional, translation: .none)))

        model.clear()

        #expect(model.phrases.map(\.id.rawValue) == [3, 4])
    }

    @Test func transcriptPairsSourceWithEnglish() {
        let model = makeModel()
        model.apply(.phrase(phrase(1, "Hola.", translation: .completed("Hello."))))
        model.apply(.phrase(phrase(2, "Thank you.", translation: .completed("Thank you."), language: "en")))
        model.apply(.phrase(phrase(3, "Merci", translation: .unavailable(.failed), language: "fr")))
        model.apply(.phrase(phrase(4, "bon", state: .provisional, translation: .none, language: nil)))

        #expect(model.transcript() == "Hola.\nHello.\n\nThank you.\n\nMerci")
    }

    // MARK: Notices

    @Test func rateLimitNoticeSaysWhenToRetry() {
        let soon = TranslationViewModel.notice(for: .usageLimitReached(retryAfter: 29.2))
        #expect(soon.message.contains("30 seconds"))

        let exhausted = TranslationViewModel.notice(for: .usageLimitReached(retryAfter: nil))
        #expect(exhausted.message.contains("credits"))
    }

    @Test func keyAndPermissionNoticesOfferAFix() {
        #expect(TranslationViewModel.notice(for: .microphoneDenied).action == .openSystemSettings)
        #expect(TranslationViewModel.notice(for: .notConfigured).action == .openAPIKeySettings)
        #expect(TranslationViewModel.notice(for: .unauthorized).action == .openAPIKeySettings)
        #expect(TranslationViewModel.notice(for: .connectionFailed).action == nil)
    }
}
