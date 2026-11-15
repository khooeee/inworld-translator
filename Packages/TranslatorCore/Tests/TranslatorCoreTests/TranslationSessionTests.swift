import Foundation
import Testing
@testable import TranslatorCore

@Suite("TranslationSession", .timeLimit(.minutes(1)))
struct TranslationSessionTests {
    // MARK: Transcripts

    @Test("interims revise one provisional phrase; the final commits it once")
    func revisions() async throws {
        let harness = SessionHarness()
        harness.translator.autoReply { _ in ("Good morning, how are you?", "es") }
        let connection = try await harness.startListening()

        connection.interim("buenos")
        connection.interim("buenos días")
        connection.interim("buenos días cómo")
        try await harness.waitForPhrases("three revisions") { $0.first?.sourceText == "buenos días cómo" }
        #expect(harness.phrases.count == 1)
        #expect(harness.phrases[0].sourceState == .provisional)
        #expect(harness.phrases[0].translation == .none)
        #expect(harness.translator.calls.isEmpty, "provisional text is never translated")

        connection.final("Buenos días, ¿cómo está?")
        try await harness.waitForPhrases("translation") { $0.first?.english != nil }

        let phrase = try #require(harness.phrases.first)
        #expect(harness.phrases.count == 1)
        #expect(phrase.sourceText == "Buenos días, ¿cómo está?")
        #expect(phrase.sourceState == .final)
        #expect(phrase.english == "Good morning, how are you?")
        #expect(phrase.languageCode == "es")
        #expect(harness.translator.requests.map(\.text) == ["Buenos días, ¿cómo está?"])
        #expect(phrase.timing.finalizedAt != nil)
        #expect(phrase.timing.translationLatency != nil)
        await harness.session.stop()
    }

    @Test("a repeated interim does not emit a new event")
    func duplicateInterims() async throws {
        let harness = SessionHarness()
        let connection = try await harness.startListening()
        connection.interim("hola")
        connection.interim("hola")
        connection.interim("hola")
        connection.interim("hola amigo")
        try await harness.waitForPhrases("revision") { $0.first?.sourceText == "hola amigo" }
        let id = harness.phrases[0].id
        #expect(harness.history(of: id).map(\.sourceText) == ["hola", "hola amigo"])
        await harness.session.stop()
    }

    @Test("a final with no words retracts its provisional phrase")
    func retractedNoise() async throws {
        let harness = SessionHarness()
        let connection = try await harness.startListening()
        connection.interim("mm")
        try await harness.waitForPhrases("provisional") { $0.count == 1 }
        let id = harness.phrases[0].id
        connection.final(" . ")
        try await eventually("removal") { harness.events.contains(.removed(id)) }
        #expect(harness.phrases.isEmpty)
        #expect(harness.translator.calls.isEmpty)
        await harness.session.stop()
    }

    @Test("a final without interims still becomes a phrase")
    func finalOnly() async throws {
        let harness = SessionHarness()
        harness.translator.autoReply { _ in ("Thank you.", "ja") }
        let connection = try await harness.startListening()
        connection.final("ありがとう。")
        try await harness.waitForPhrases("translated") { $0.first?.english == "Thank you." }
        #expect(harness.phrases.count == 1)
        await harness.session.stop()
    }

    @Test("language switches between phrases are followed without configuration")
    func languageSwitching() async throws {
        let harness = SessionHarness()
        let lines: [(String, String, String)] = [
            ("Hola, me llamo Ana.", "Hello, my name is Ana.", "es"),
            ("今日はいい天気ですね。", "Nice weather today, isn't it?", "ja"),
            ("Ich komme aus Berlin.", "I come from Berlin.", "de"),
            ("And I'm from Boston.", "And I'm from Boston.", "en"),
        ]
        harness.translator.autoReply { request in
            let line = lines.first { $0.0 == request.text }!
            return (line.1, line.2)
        }
        let connection = try await harness.startListening()
        for line in lines {
            connection.interim(String(line.0.prefix(4)))
            connection.final(line.0)
        }
        try await harness.waitForPhrases("all translated") { $0.count == 4 && $0.allSatisfy { $0.english != nil } }

        #expect(harness.phrases.map(\.sourceText) == lines.map(\.0))
        #expect(harness.phrases.map(\.english) == lines.map(\.1))
        #expect(harness.phrases.map(\.languageCode) == lines.map(\.2))
        #expect(harness.phrases.last?.isSpokenInEnglish == true)
        // The STT stream is never given a language hint.
        let configuration = try #require(harness.stt.state.withLock { $0.configurations.first })
        #expect(configuration == STTConfiguration())
        await harness.session.stop()
    }

    // MARK: Translation ordering

    @Test("responses that arrive out of order land on their own phrases")
    func outOfOrderResponses() async throws {
        let harness = SessionHarness()
        let connection = try await harness.startListening()
        connection.final("uno")
        connection.final("dos")
        let first = try await harness.translator.call(0)
        let second = try await harness.translator.call(1)

        second.reply("two", language: "es")
        try await harness.waitForPhrases("second done") { $0.count == 2 && $0[1].english == "two" }
        #expect(harness.phrases[0].english == nil, "the first phrase is still waiting")

        first.reply("one", language: "es")
        try await harness.waitForPhrases("first done") { $0.first?.english == "one" }
        #expect(harness.phrases.map(\.sourceText) == ["uno", "dos"])
        #expect(harness.phrases.map(\.english) == ["one", "two"])
        await harness.session.stop()
    }

    @Test("partial translations stream onto the phrase as they arrive")
    func partialTranslation() async throws {
        let harness = SessionHarness()
        let connection = try await harness.startListening()
        connection.final("Der Zug fährt um acht Uhr.")
        let call = try await harness.translator.call(0)
        call.continuation.yield(.language("de"))
        call.partial("The train")
        try await harness.waitForPhrases("partial") { $0.first?.translation == .partial("The train") }
        #expect(harness.phrases[0].languageCode == "de")
        call.partial(" leaves at eight.")
        try await harness.waitForPhrases("more") { $0.first?.translation == .partial("The train leaves at eight.") }
        call.reply("The train leaves at eight o'clock.")
        try await harness.waitForPhrases("completed") { $0.first?.english == "The train leaves at eight o'clock." }
        #expect(harness.phrases[0].timing.firstTextLatency != nil)
        await harness.session.stop()
    }

    @Test("each request carries the recent phrases as context")
    func context() async throws {
        let harness = SessionHarness(translation: { $0.contextSize = 2 })
        harness.translator.autoReply { request in ("EN(\(request.text))", "fr") }
        let connection = try await harness.startListening()
        for text in ["a", "b", "c", "d"] {
            connection.final(text)
            try await harness.waitForPhrases(text) { $0.last?.english == "EN(\(text))" }
        }
        let requests = harness.translator.requests
        #expect(requests[0].context.isEmpty)
        #expect(requests[1].context == [.init(source: "a", translation: "EN(a)")])
        #expect(requests[3].context == [.init(source: "b", translation: "EN(b)"), .init(source: "c", translation: "EN(c)")])
        await harness.session.stop()
    }

    @Test("listening continues while translations are slow")
    func listeningDuringTranslation() async throws {
        let harness = SessionHarness()
        let connection = try await harness.startListening()
        connection.final("primera")
        _ = try await harness.translator.call(0)
        // The first translation never returns, but speech keeps flowing.
        harness.audio.speak(7)
        connection.interim("segunda")
        try await harness.waitForPhrases("second phrase") { $0.count == 2 }
        try await eventually("audio sent") { connection.audioMarkers.contains(7) }
        #expect(harness.status == .listening)
        await harness.session.stop()
    }

    @Test("a backlog is bounded by skipping the oldest waiting phrase")
    func boundedBacklog() async throws {
        let harness = SessionHarness(translation: {
            $0.maxConcurrent = 1
            $0.maxWaiting = 2
        })
        let connection = try await harness.startListening()
        for text in ["p1", "p2", "p3", "p4", "p5"] {
            connection.final(text)
        }
        try await harness.waitForPhrases("five phrases") { $0.count == 5 }
        // p1 is in flight; p2 and p3 were pushed out of the two waiting slots.
        try await harness.waitForPhrases("skips") {
            $0[1].translation == .unavailable(.skipped) && $0[2].translation == .unavailable(.skipped)
        }
        #expect(harness.translator.calls.count == 1)

        try await harness.translator.call(0).reply("P1")
        try await harness.translator.call(1).reply("P4")
        try await harness.translator.call(2).reply("P5")
        try await harness.waitForPhrases("rest done") { $0.last?.english == "P5" }
        #expect(harness.phrases.map(\.english) == ["P1", nil, nil, "P4", "P5"])
        #expect(harness.translator.requests.map(\.text) == ["p1", "p4", "p5"])
        await harness.session.stop()
    }

    @Test("a momentary failure is retried once; a second failure is reported")
    func retry() async throws {
        let harness = SessionHarness()
        let connection = try await harness.startListening()
        connection.final("hola")
        try await harness.translator.call(0).fail(BackendError.server(status: 502))
        try await harness.translator.call(1).reply("hello")
        try await harness.waitForPhrases("retried") { $0.first?.english == "hello" }
        #expect(harness.translator.requests.map(\.text) == ["hola", "hola"])

        connection.final("adiós")
        try await harness.translator.call(2).fail(BackendError.transport)
        try await harness.translator.call(3).fail(BackendError.transport)
        try await harness.waitForPhrases("failed") { $0.last?.translation == .unavailable(.failed) }
        #expect(harness.translator.calls.count == 4)
        await harness.session.stop()
    }

    @Test("a translation that takes too long is abandoned without a retry")
    func translationTimeout() async throws {
        let harness = SessionHarness(translation: { $0.requestTimeout = .milliseconds(100) })
        let connection = try await harness.startListening()
        connection.final("lento")
        let call = try await harness.translator.call(0)
        try await harness.waitForPhrases("timed out") { $0.first?.translation == .unavailable(.failed) }
        try await eventually("request cancelled") { call.isCancelled }
        #expect(harness.translator.calls.count == 1)
        // A response after the deadline changes nothing.
        call.reply("too late")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.phrases[0].translation == .unavailable(.failed))
        await harness.session.stop()
    }

    @Test("an empty translation marks the phrase unintelligible")
    func unintelligible() async throws {
        let harness = SessionHarness()
        harness.translator.autoReply { _ in ("", "und") }
        let connection = try await harness.startListening()
        connection.final("hmm")
        try await harness.waitForPhrases("und") { $0.first?.translation == .unavailable(.unintelligible) }
        await harness.session.stop()
    }

    @Test("translation limits are reported once and listening continues")
    func translationLimited() async throws {
        let harness = SessionHarness()
        let connection = try await harness.startListening()
        connection.final("uno")
        try await harness.translator.call(0).fail(BackendError.rateLimited(retryAfter: 30))
        connection.final("dos")
        try await harness.translator.call(1).fail(BackendError.quotaExceeded(retryAfter: 3600))
        try await harness.waitForPhrases("limited") { $0.count == 2 && $0.allSatisfy { $0.translation == .unavailable(.limitReached) } }
        #expect(harness.notices == [.translationLimited])
        #expect(harness.status == .listening)
        #expect(harness.translator.calls.count == 2, "limits are not retried")
        await harness.session.stop()
    }

    // MARK: Stop

    @Test("Stop releases the microphone and finalizes the last turn")
    func stopFinalizes() async throws {
        let harness = SessionHarness()
        harness.translator.autoReply { _ in ("See you tomorrow.", "es") }
        harness.stt.onFinish([.final("Hasta mañana.")])
        let connection = try await harness.startListening()
        harness.audio.speak(1)
        connection.interim("hasta")
        try await harness.waitForPhrases("provisional") { $0.count == 1 }

        await harness.session.stop()

        #expect(!harness.audio.isCapturing)
        #expect(harness.audio.stops == 1)
        #expect(connection.finishRequested, "closeStream lets the service finalize")
        #expect(harness.status == .idle)
        let phrase = try #require(harness.phrases.first)
        #expect(harness.phrases.count == 1)
        #expect(phrase.sourceText == "Hasta mañana.")
        #expect(phrase.sourceState == .final)
        #expect(phrase.english == "See you tomorrow.", "translations already under way may finish")
        #expect(harness.statuses.suffix(2) == [.finishing, .idle])
        #expect(harness.events.contains(.level(0)))
    }

    @Test("Stop cancels translations that outlast the drain timeout")
    func stopCancelsPending() async throws {
        let harness = SessionHarness(configure: { $0.translationDrainTimeout = .milliseconds(50) })
        let connection = try await harness.startListening()
        connection.final("uno")
        let call = try await harness.translator.call(0)

        await harness.session.stop()

        #expect(call.isCancelled)
        #expect(harness.status == .idle)
        try await harness.waitForPhrases("cancelled") { $0.first?.translation == .unavailable(.cancelled) }
        // A reply after Stop has no effect.
        call.reply("one")
        try await Task.sleep(for: .milliseconds(30))
        #expect(harness.phrases[0].translation == .unavailable(.cancelled))
    }

    @Test("Stop commits the open phrase when the service never finalizes it")
    func stopWithoutFinal() async throws {
        let harness = SessionHarness()
        harness.translator.autoReply { _ in ("the train", "de") }
        let connection = try await harness.startListening()
        connection.interim("der zug")
        try await harness.waitForPhrases("provisional") { $0.count == 1 }
        await harness.session.stop()
        let phrase = try #require(harness.phrases.first)
        #expect(phrase.sourceState == .interrupted)
        #expect(phrase.english == "the train")
    }

    @Test("Stop while the microphone is still starting releases it")
    func stopDuringStartup() async throws {
        let harness = SessionHarness()
        harness.audio.delayStarts(.milliseconds(100))
        await harness.session.start()
        try await Task.sleep(for: .milliseconds(20))
        await harness.session.stop()
        #expect(harness.audio.starts == 1)
        #expect(harness.audio.stops >= 1)
        #expect(!harness.audio.isCapturing)
        #expect(harness.stt.count == 0, "no connection is opened after Stop")
        #expect(harness.status == .idle)
    }

    @Test("Stop and Start in quick succession leave one clean session")
    func restart() async throws {
        let harness = SessionHarness()
        harness.translator.autoReply { request in ("EN \(request.text)", "es") }
        let first = try await harness.startListening()
        first.final("uno")
        try await harness.waitForPhrases("first") { $0.first?.english == "EN uno" }

        for _ in 0..<5 {
            await harness.session.start()
            await harness.session.stop()
        }
        await harness.session.start()
        try await harness.waitForStatus(.listening)
        let latest = try #require(harness.stt.latest)
        latest.final("dos")
        try await harness.waitForPhrases("second") { $0.last?.english == "EN dos" }

        #expect(harness.audio.isCapturing)
        #expect(harness.audio.starts == harness.audio.stops + 1)
        let ids = harness.phrases.map(\.id)
        #expect(ids == ids.sorted() && Set(ids).count == ids.count)
        // Only the newest connection is still open.
        #expect(harness.stt.connections.dropLast().allSatisfy { $0.isCancelled || $0.finishRequested })
        await harness.session.stop()
        #expect(!harness.audio.isCapturing)
    }

    @Test("Stop is safe to repeat and to call when idle")
    func repeatedStop() async throws {
        let harness = SessionHarness()
        await harness.session.stop()
        _ = try await harness.startListening()
        async let a: Void = harness.session.stop()
        async let b: Void = harness.session.stop()
        _ = await (a, b)
        await harness.session.stop()
        #expect(harness.audio.stops == 1)
        #expect(harness.status == .idle)
    }

    // MARK: Reconnects

    @Test("a dropped connection reconnects with a fresh credential and keeps the audio")
    func reconnect() async throws {
        let harness = SessionHarness()
        harness.translator.autoReply { request in ("EN \(request.text)", "it") }
        let first = try await harness.startListening()
        harness.audio.speak(1)
        try await eventually("audio 1") { first.audioMarkers == [1] }
        first.interim("buongiorno a")
        try await harness.waitForPhrases("provisional") { $0.count == 1 }

        first.drop()
        // Audio captured while reconnecting is held and sent afterwards, in order.
        harness.audio.speak(2)
        harness.audio.speak(3)
        let second = try await harness.stt.connection(1)
        try await harness.waitForStatus(.listening)
        harness.audio.speak(4)
        try await eventually("audio replayed") { second.audioMarkers == [2, 3, 4] }

        // The open turn was committed from its last interim when the socket dropped.
        try await harness.waitForPhrases("interrupted phrase translated") { $0.first?.english == "EN buongiorno a" }
        #expect(harness.phrases[0].sourceState == .interrupted)

        // A late result from the dead connection is ignored.
        first.final("should not appear")
        second.final("tutti")
        try await harness.waitForPhrases("second phrase") { $0.count == 2 && $0[1].english == "EN tutti" }
        #expect(!harness.phrases.contains { $0.sourceText == "should not appear" })

        #expect(harness.credentials.issued.map(\.accessToken) == ["token-0", "token-1"])
        #expect(second.credential.accessToken == "token-1", "single-use tokens are never reused")
        #expect(harness.statuses.contains(.reconnecting))
        await harness.session.stop()
    }

    @Test("audio held while disconnected is bounded")
    func boundedPendingAudio() async throws {
        let harness = SessionHarness(configure: {
            $0.maxPendingAudioBytes = 960
            $0.reconnectBaseDelay = .milliseconds(200)
            $0.reconnectMaxDelay = .milliseconds(200)
        })
        let first = try await harness.startListening()
        first.drop()
        try await harness.waitForStatus(.reconnecting)
        for marker in UInt8(1)...10 {
            harness.audio.speak(marker, bytes: 320)
        }
        let second = try await harness.stt.connection(1)
        try await harness.waitForStatus(.listening)
        // The pump is the only sender, so held audio goes out ahead of the next live chunk.
        harness.audio.speak(11, bytes: 320)
        try await eventually("replay") { second.audioMarkers.count == 4 }
        #expect(second.audioMarkers == [8, 9, 10, 11], "only the newest held audio is kept")
        await harness.session.stop()
    }

    @Test("connection failures back off and eventually give up")
    func givesUp() async throws {
        let harness = SessionHarness(configure: { $0.maxReconnectAttempts = 3 })
        harness.stt.failNext(
            STTConnectionError.connectFailed,
            STTConnectionError.connectFailed,
            STTConnectionError.connectFailed,
            STTConnectionError.connectFailed
        )
        await harness.session.start()
        try await harness.waitForStatus(.idle)
        #expect(harness.notices == [.connectionFailed])
        #expect(harness.credentials.issued.count == 4)
        #expect(!harness.audio.isCapturing)
    }

    @Test("a credential failure is retried, then the connection succeeds")
    func credentialRetry() async throws {
        let harness = SessionHarness()
        harness.credentials.failNext(BackendError.transport, BackendError.server(status: 502))
        await harness.session.start()
        _ = try await harness.stt.connection(0)
        try await harness.waitForStatus(.listening)
        #expect(harness.notices.isEmpty)
        await harness.session.stop()
    }

    @Test("an authentication rejection from the service gets a fresh credential")
    func serviceAuthRejection() async throws {
        let harness = SessionHarness()
        let first = try await harness.startListening()
        first.fail(STTServiceError(code: 16, message: "The session token is invalid or has expired."))
        let second = try await harness.stt.connection(1)
        try await harness.waitForStatus(.listening)
        #expect(second.credential.accessToken == "token-1")
        await harness.session.stop()
    }

    @Test("a rejected configuration stops instead of reconnecting forever")
    func invalidArgument() async throws {
        let harness = SessionHarness()
        let first = try await harness.startListening()
        first.fail(STTServiceError(code: 3, message: "invalid transcribe config"))
        try await harness.waitForStatus(.idle)
        #expect(harness.notices == [.serviceRejectedRequest])
        #expect(harness.stt.count == 1)
        #expect(!harness.audio.isCapturing)
    }

    @Test("a revoked client key stops the session")
    func unauthorized() async throws {
        let harness = SessionHarness()
        harness.credentials.failNext(BackendError.unauthorized)
        await harness.session.start()
        try await harness.waitForStatus(.idle)
        #expect(harness.notices == [.unauthorized])
        #expect(!harness.audio.isCapturing)
    }

    @Test("a long rate limit or a daily quota stops with the retry time")
    func usageLimit() async throws {
        let harness = SessionHarness()
        harness.credentials.failNext(BackendError.quotaExceeded(retryAfter: 3600))
        await harness.session.start()
        try await harness.waitForStatus(.idle)
        #expect(harness.notices == [.usageLimitReached(retryAfter: 3600)])
    }

    @Test("a short rate limit is waited out")
    func shortRateLimit() async throws {
        let harness = SessionHarness()
        harness.credentials.failNext(BackendError.rateLimited(retryAfter: 0.05))
        await harness.session.start()
        _ = try await harness.stt.connection(0)
        try await harness.waitForStatus(.listening)
        #expect(harness.notices.isEmpty)
        await harness.session.stop()
    }

    @Test("losing the network waits, then reconnects as soon as it returns")
    func networkLoss() async throws {
        let harness = SessionHarness(configure: {
            $0.reconnectBaseDelay = .seconds(5)
            $0.reconnectMaxDelay = .seconds(5)
        })
        let first = try await harness.startListening()
        harness.connectivity.set(false)
        try await harness.waitForStatus(.waitingForNetwork)
        #expect(first.isCancelled, "a socket on a dead network is closed at once")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.stt.count == 1, "no attempts while offline")

        harness.connectivity.set(true)
        _ = try await harness.stt.connection(1)
        try await harness.waitForStatus(.listening)
        await harness.session.stop()
    }

    @Test("a send failure closes the socket and the chunk is resent after reconnecting")
    func sendFailure() async throws {
        let harness = SessionHarness()
        let first = try await harness.startListening()
        first.state.withLock { $0.sendError = STTConnectionError.disconnected }
        harness.audio.speak(5)
        let second = try await harness.stt.connection(1)
        try await harness.waitForStatus(.listening)
        harness.audio.speak(6)
        try await eventually("resent") { second.audioMarkers == [5, 6] }
        await harness.session.stop()
    }

    // MARK: Interruptions and microphone

    @Test("a phone call suspends listening and resumes afterwards")
    func interruption() async throws {
        let harness = SessionHarness()
        harness.translator.autoReply { request in ("EN \(request.text)", "pt") }
        let first = try await harness.startListening()
        first.interim("bom dia")
        try await harness.waitForPhrases("provisional") { $0.count == 1 }

        harness.audio.send(.interruptionBegan)
        try await harness.waitForStatus(.interrupted)
        #expect(first.isCancelled)
        try await harness.waitForPhrases("committed") { $0.first?.sourceState == .interrupted }
        harness.audio.speak(9)
        try await Task.sleep(for: .milliseconds(30))
        #expect(harness.stt.count == 1, "no connection during the call")

        harness.audio.send(.interruptionEnded(resumed: true))
        let second = try await harness.stt.connection(1)
        try await harness.waitForStatus(.listening)
        harness.audio.speak(10)
        try await eventually("audio after call") { second.audioMarkers == [10] }
        #expect(!second.audioMarkers.contains(9), "audio from during the call is not sent")
        await harness.session.stop()
    }

    @Test("an interruption that does not resume stops the session")
    func interruptionWithoutResume() async throws {
        let harness = SessionHarness()
        _ = try await harness.startListening()
        harness.audio.send(.interruptionBegan)
        try await harness.waitForStatus(.interrupted)
        harness.audio.send(.interruptionEnded(resumed: false))
        try await harness.waitForStatus(.idle)
        #expect(harness.notices == [.stoppedByInterruption])
        #expect(!harness.audio.isCapturing)
    }

    @Test("microphone permission denied is reported and nothing connects")
    func permissionDenied() async throws {
        let harness = SessionHarness()
        harness.audio.failNextStart(.permissionDenied)
        await harness.session.start()
        try await harness.waitForStatus(.idle)
        #expect(harness.notices == [.microphoneDenied])
        #expect(harness.credentials.issued.isEmpty)
        #expect(harness.stt.count == 0)
    }

    @Test("a capture failure stops the session")
    func captureFailure() async throws {
        let harness = SessionHarness()
        _ = try await harness.startListening()
        harness.audio.send(.failed)
        try await harness.waitForStatus(.idle)
        #expect(harness.notices == [.microphoneUnavailable])
    }

    @Test("microphone levels are forwarded")
    func levels() async throws {
        let harness = SessionHarness()
        _ = try await harness.startListening()
        harness.audio.speak(1, level: 0.25)
        try await eventually("level") { harness.events.contains(.level(0.25)) }
        await harness.session.stop()
    }

    // MARK: Timers

    @Test("a session with no speech stops itself")
    func idleTimeout() async throws {
        let harness = SessionHarness(configure: { $0.idleTimeout = .milliseconds(100) })
        _ = try await harness.startListening()
        try await harness.waitForStatus(.idle)
        #expect(harness.notices == [.stoppedAfterSilence])
        #expect(!harness.audio.isCapturing)
    }

    @Test("a turn that runs too long is asked to finalize, once")
    func maxTurnDuration() async throws {
        let harness = SessionHarness(configure: { $0.maxTurnDuration = .milliseconds(60) })
        let connection = try await harness.startListening()
        connection.interim("una frase muy larga")
        try await eventually("endTurn") { connection.endTurns == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(connection.endTurns == 1)
        connection.final("Una frase muy larga.")
        connection.interim("otra")
        try await eventually("second endTurn") { connection.endTurns == 2 }
        await harness.session.stop()
    }
}
