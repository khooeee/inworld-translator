import Foundation
import Synchronization
import Testing
@testable import TranslatorCore

/// Records a speech queue's events.
private final class QueueRecorder: Sendable {
    private final class Log: Sendable {
        let events = Mutex<[SpeechQueue.Event]>([])
    }

    private let log = Log()
    private let task: Task<Void, Never>

    init(_ queue: SpeechQueue) {
        let log = self.log
        task = Task {
            for await event in queue.events {
                log.events.withLock { $0.append(event) }
            }
        }
    }

    deinit {
        task.cancel()
    }

    var recorded: [SpeechQueue.Event] { log.events.withLock { $0 } }
}

@Suite("SpeechQueue", .timeLimit(.minutes(1)))
struct SpeechQueueTests {
    let speech = FakeSpeech()

    func makeQueue(maxWaiting: Int = 2) -> SpeechQueue {
        var configuration = SpeechQueue.Configuration()
        configuration.maxWaiting = maxWaiting
        return SpeechQueue(synthesizer: speech, player: speech, configuration: configuration)
    }

    @Test("speaks one phrase at a time, in the order given")
    func order() async throws {
        speech.holdPlayback()
        let queue = makeQueue()
        let recorder = QueueRecorder(queue)
        queue.enqueue(id: PhraseID(1), text: "Hello.")
        queue.enqueue(id: PhraseID(2), text: "How are you?")

        try await eventually("first playing") { speech.playing == "Hello." }
        #expect(speech.requested == ["Hello."], "the next is not requested while one plays")
        speech.finishPlaying()
        try await eventually("second playing") { speech.playing == "How are you?" }
        speech.finishPlaying()
        try await eventually("both played") { speech.played.count == 2 }
        try await eventually("idle") { recorder.recorded.last == .speaking(nil) }

        #expect(speech.played == ["Hello.", "How are you?"])
        #expect(recorder.recorded == [.speaking(PhraseID(1)), .speaking(PhraseID(2)), .speaking(nil)])
    }

    @Test("waits while someone is speaking, but finishes a phrase already started")
    func floor() async throws {
        speech.holdPlayback()
        let queue = makeQueue()
        queue.setFloorTaken(true)
        queue.enqueue(id: PhraseID(1), text: "One.")
        try await Task.sleep(for: .milliseconds(50))
        #expect(speech.requested.isEmpty)

        queue.setFloorTaken(false)
        try await eventually("playing") { speech.playing == "One." }
        queue.enqueue(id: PhraseID(2), text: "Two.")
        queue.setFloorTaken(true)
        speech.finishPlaying()
        try await eventually("first played") { speech.played == ["One."] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(speech.requested == ["One."], "the next waits for the pause")

        queue.setFloorTaken(false)
        try await eventually("second playing") { speech.playing == "Two." }
        speech.finishPlaying()
        try await eventually("second played") { speech.played == ["One.", "Two."] }
    }

    @Test("a backlog drops the oldest waiting phrase")
    func backlog() async throws {
        speech.holdPlayback()
        let queue = makeQueue(maxWaiting: 2)
        for id in 1...5 {
            queue.enqueue(id: PhraseID(id), text: "\(id)")
        }
        for count in 1...3 {
            try await eventually("playing") { speech.playing != nil }
            speech.finishPlaying()
            try await eventually("played \(count)") { speech.played.count == count }
        }
        #expect(speech.played == ["1", "4", "5"])
    }

    @Test("stop cuts the phrase being spoken and forgets the rest")
    func stop() async throws {
        speech.holdPlayback()
        let queue = makeQueue()
        let recorder = QueueRecorder(queue)
        queue.enqueue(id: PhraseID(1), text: "One.")
        queue.enqueue(id: PhraseID(2), text: "Two.")
        try await eventually("playing") { speech.playing == "One." }

        await queue.stop()

        #expect(speech.playing == nil, "stop returns once the sound has stopped")
        #expect(speech.cutShort == ["One."])
        try await Task.sleep(for: .milliseconds(50))
        #expect(speech.requested == ["One."])
        #expect(recorder.recorded == [.speaking(PhraseID(1)), .speaking(nil)])
        #expect(!recorder.recorded.contains { if case .failed = $0 { true } else { false } }, "a stop is not a failure")

        // Still usable afterwards.
        queue.enqueue(id: PhraseID(3), text: "Three.")
        try await eventually("playing") { speech.playing == "Three." }
        speech.finishPlaying()
        try await eventually("played") { speech.played == ["Three."] }
    }

    @Test("a failed phrase is reported and the next one still plays")
    func failure() async throws {
        speech.failNext(ServiceError.quotaExceeded)
        let queue = makeQueue()
        let recorder = QueueRecorder(queue)
        queue.enqueue(id: PhraseID(1), text: "One.")
        queue.enqueue(id: PhraseID(2), text: "Two.")
        try await eventually("played") { speech.played == ["Two."] }
        try await eventually("idle") { recorder.recorded.last == .speaking(nil) }
        #expect(recorder.recorded == [.speaking(PhraseID(1)), .failed(.quotaExceeded), .speaking(PhraseID(2)), .speaking(nil)])
    }
}

@Suite("TranslationSession speech", .timeLimit(.minutes(1)))
struct SessionSpeechTests {
    @Test("nothing is spoken until speech is turned on")
    func offByDefault() async throws {
        let harness = SessionHarness()
        harness.translator.autoReply { _ in ("Hello.", "es") }
        let connection = try await harness.startListening()
        connection.final("Hola.")
        try await harness.waitForPhrases("translated") { $0.first?.english == "Hello." }
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.speech.requested.isEmpty)
        await harness.session.stop()
    }

    @Test("English is spoken in the order phrases were heard, even when translations finish out of order")
    func conversationOrder() async throws {
        let harness = SessionHarness()
        await harness.session.setSpeaksTranslations(true)
        let connection = try await harness.startListening()
        connection.final("Uno.")
        connection.final("Dos.")
        let first = try await harness.translator.call(0)
        let second = try await harness.translator.call(1)

        second.reply("Two.", language: "es")
        try await harness.waitForPhrases("second translated") { $0.last?.english == "Two." }
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.speech.requested.isEmpty, "the second waits for the first")

        first.reply("One.", language: "es")
        try await eventually("both spoken") { harness.speech.played == ["One.", "Two."] }
        let ids = harness.phrases.map(\.id)
        try await eventually("speaking events") { harness.speaking.last == .some(nil) }
        #expect(harness.speaking.compactMap { $0 } == ids)
        await harness.session.stop()
    }

    @Test("English speech, failed translations, and unintelligible phrases are not spoken")
    func skipped() async throws {
        let harness = SessionHarness()
        await harness.session.setSpeaksTranslations(true)
        let connection = try await harness.startListening()
        connection.final("Thank you.")
        connection.final("Merci.")
        connection.final("mm")
        connection.final("Gracias.")
        // Two translations run at a time.
        try await harness.translator.call(0).reply("Thank you.", language: "en")
        try await harness.translator.call(1).fail(ServiceError.quotaExceeded)
        try await harness.translator.call(2).reply("", language: "und")
        try await harness.translator.call(3).reply("Thanks.", language: "es")

        try await eventually("spoken") { harness.speech.played == ["Thanks."] }
        #expect(harness.speech.requested == ["Thanks."])
        await harness.session.stop()
    }

    @Test("speech waits for the speaker to finish their sentence")
    func waitsForPause() async throws {
        let harness = SessionHarness()
        harness.translator.autoReply { _ in ("Hello.", "es") }
        await harness.session.setSpeaksTranslations(true)
        let connection = try await harness.startListening()
        connection.final("Hola.")
        connection.interim("y también")
        try await harness.waitForPhrases("translated") { $0.first?.english == "Hello." }
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.speech.requested.isEmpty)

        connection.final("Y también adiós.")
        try await eventually("spoken") { harness.speech.played.first == "Hello." }
        await harness.session.stop()
    }

    @Test("Stop silences speech at once and nothing more is said")
    func stopSilences() async throws {
        let harness = SessionHarness()
        harness.speech.holdPlayback()
        await harness.session.setSpeaksTranslations(true)
        let connection = try await harness.startListening()
        connection.final("Uno.")
        connection.final("Dos.")
        try await harness.translator.call(1)
        harness.translator.calls[0].reply("One.", language: "es")
        try await eventually("speaking") { harness.speech.playing == "One." }

        await harness.session.stop()

        #expect(harness.speech.cutShort == ["One."])
        harness.translator.calls[1].reply("Two.", language: "es")
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.speech.requested == ["One."])
        #expect(harness.speaking.last == .some(nil))
    }

    @Test("turning speech off stops it mid-phrase")
    func turnOff() async throws {
        let harness = SessionHarness()
        harness.speech.holdPlayback()
        harness.translator.autoReply { _ in ("One.", "es") }
        await harness.session.setSpeaksTranslations(true)
        let connection = try await harness.startListening()
        connection.final("Uno.")
        try await eventually("speaking") { harness.speech.playing == "One." }

        await harness.session.setSpeaksTranslations(false)

        #expect(harness.speech.cutShort == ["One."])
        connection.final("Dos.")
        try await harness.waitForPhrases("translated") { $0.count == 2 && $0.allSatisfy(\.isSettled) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.speech.requested == ["One."])
        await harness.session.stop()
    }

    @Test("a phone call silences speech")
    func interruption() async throws {
        let harness = SessionHarness()
        harness.speech.holdPlayback()
        harness.translator.autoReply { _ in ("One.", "es") }
        await harness.session.setSpeaksTranslations(true)
        let connection = try await harness.startListening()
        connection.final("Uno.")
        try await eventually("speaking") { harness.speech.playing == "One." }

        harness.audio.send(.interruptionBegan)

        try await eventually("cut short") { harness.speech.cutShort == ["One."] }
        await harness.session.stop()
    }

    @Test("a speech failure is reported once and captions carry on")
    func failure() async throws {
        let harness = SessionHarness()
        harness.speech.failNext(ServiceError.unauthorized, ServiceError.unauthorized)
        harness.translator.autoReply { request in (request.text == "Uno." ? "One." : "Two.", "es") }
        await harness.session.setSpeaksTranslations(true)
        let connection = try await harness.startListening()
        connection.final("Uno.")
        connection.final("Dos.")

        try await eventually("both attempted") { harness.speech.requested.count == 2 }
        try await eventually("notice") { harness.notices == [.speechUnavailable] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.notices == [.speechUnavailable])
        #expect(harness.status == .listening)
        await harness.session.stop()
    }
}
