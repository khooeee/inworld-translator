import Foundation
import Testing
@testable import TranslatorCore

@Suite("STT wire format")
struct STTWireTests {
    @Test("the config message auto-detects language and sends binary audio")
    func config() throws {
        let message = try STTWire.configMessage(modelID: "inworld/inworld-stt-1", configuration: STTConfiguration())
        let json = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        #expect(json["audioProtocol"] as? String == "BINARY")
        let config = try #require(json["transcribeConfig"] as? [String: Any])
        #expect(config["modelId"] as? String == "inworld/inworld-stt-1")
        #expect(config["audioEncoding"] as? String == "LINEAR16")
        #expect(config["sampleRateHertz"] as? Int == 16_000)
        #expect(config["numberOfChannels"] as? Int == 1)
        #expect(config["language"] == nil, "a hint would pin the output script and stop language switching")
        #expect(config["inworldSttV1Config"] == nil)
    }

    @Test("turn-detection tuning is sent only when set")
    func tuning() throws {
        let configuration = STTConfiguration(
            endOfTurnConfidenceThreshold: 0.6,
            minEndOfTurnSilenceMilliseconds: 300,
            maxTurnSilenceMilliseconds: 1200
        )
        let message = try STTWire.configMessage(modelID: "m", configuration: configuration)
        #expect(message.contains(#""endOfTurnConfidenceThreshold":0.6"#))
        #expect(message.contains(#""inworldSttV1Config":{"maxTurnSilence":1200,"minEndOfTurnSilenceWhenConfident":300}"#))
    }

    @Test("server messages decode to events")
    func decode() {
        #expect(STTWire.decode(#"{"result":{"transcription":{"transcript":"Please open","isFinal":false}}}"#) == .event(.interim("Please open")))
        #expect(STTWire.decode(#"{"result":{"transcription":{"transcript":"Please open the door.","isFinal":true,"wordTimestamps":[],"voiceProfile":null,"silenceDurationMs":0}}}"#) == .event(.final("Please open the door.")))
        // Defaults may be omitted from the JSON.
        #expect(STTWire.decode(#"{"result":{"transcription":{"transcript":"hi"}}}"#) == .event(.interim("hi")))
        #expect(STTWire.decode(#"{"result":{"transcription":{"isFinal":true}}}"#) == .event(.final("")))
        #expect(STTWire.decode(#"{"result":{"speechStarted":{"startTimeMs":0,"confidence":0}}}"#) == .event(.speechStarted))
        #expect(STTWire.decode(#"{"result":{"speechStopped":{"silenceDurationMs":150}}}"#) == .event(.speechStopped))
        #expect(STTWire.decode(#"{"result":{"usage":{"transcribedAudioMs":2400,"modelId":"inworld/inworld-stt-1"}}}"#) == .event(.usage(audioMilliseconds: 2400)))
        #expect(STTWire.decode("not json") == .ignored)
        #expect(STTWire.decode(#"{"result":{}}"#) == .ignored)
    }

    @Test("error frames decode with their gRPC code")
    func errors() {
        // Captured from the live endpoint with an invalid bearer token.
        let live = #"{"error":{"code":16, "message":"The session token is invalid or has expired. Obtain a new token and reconnect.", "details":[{"@type":"type.googleapis.com/ai.inworld.common.InworldStatus", "errorType":"SESSION_TOKEN_INVALID", "reconnectType":"NO_RETRY", "reconnectTime":null, "maxRetries":0}]}}"#
        guard case .error(let error) = STTWire.decode(live) else {
            Issue.record("expected an error")
            return
        }
        #expect(error.isAuthentication)
        #expect(!error.isInvalidArgument)
        // Captured from the live endpoint with a wrong Basic key.
        guard case .error(let wrongKey) = STTWire.decode(#"{"error":{"code":7, "message":"Invalid authorization credentials", "details":[]}}"#) else {
            Issue.record("expected an error")
            return
        }
        #expect(wrongKey.isAuthentication)
        guard case .error(let invalid) = STTWire.decode(#"{"error":{"code":3,"message":"invalid transcribe config"}}"#) else {
            Issue.record("expected an error")
            return
        }
        #expect(invalid.isInvalidArgument)
    }
}

@Suite("Helpers")
struct HelperTests {
    @Test("speech detection ignores punctuation-only text")
    func containsSpeech() {
        #expect(TranslationSession.containsSpeech("hola"))
        #expect(TranslationSession.containsSpeech("三時"))
        #expect(TranslationSession.containsSpeech("42"))
        #expect(!TranslationSession.containsSpeech(""))
        #expect(!TranslationSession.containsSpeech(" . , ? "))
        #expect(!TranslationSession.containsSpeech("。"))
    }

    @Test("withTimeout cancels slow work")
    func timeout() async {
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(.milliseconds(20)) {
                try await Task.sleep(for: .seconds(5))
            }
        }
        let value = try? await withTimeout(.seconds(1)) { 7 }
        #expect(value == 7)
    }

    @Test("value(within:) returns nil for an unfinished task")
    func valueWithin() async {
        let slow = Task<Int, Never> {
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        #expect(await slow.value(within: .milliseconds(20)) == nil)
        slow.cancel()
        let fast = Task<Int, Never> { 2 }
        #expect(await fast.value(within: .seconds(1)) == 2)
    }

    @Test("Duration converts to seconds")
    func duration() {
        #expect(Duration.milliseconds(1500).timeInterval == 1.5)
    }
}
