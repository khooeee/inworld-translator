import Foundation

/// The JSON messages of Inworld's streaming STT WebSocket.
/// https://docs.inworld.ai/api-reference/sttAPI/speechtotext/transcribe-stream-websocket
enum STTWire {
    static let endTurn = #"{"endTurn":{}}"#
    static let closeStream = #"{"closeStream":{}}"#

    /// The first message on a connection. Omitting `language` lets the
    /// service detect the spoken language without a hint.
    static func configMessage(modelID: String, configuration: STTConfiguration) throws -> String {
        var tuning: TranscribeConfig.InworldSTTV1Config?
        if configuration.minEndOfTurnSilenceMilliseconds != nil || configuration.maxTurnSilenceMilliseconds != nil {
            tuning = .init(
                minEndOfTurnSilenceWhenConfident: configuration.minEndOfTurnSilenceMilliseconds,
                maxTurnSilence: configuration.maxTurnSilenceMilliseconds
            )
        }
        let message = ConfigMessage(
            transcribeConfig: .init(
                modelId: modelID,
                audioEncoding: "LINEAR16",
                language: configuration.languageHint?.rawValue,
                sampleRateHertz: configuration.sampleRate,
                numberOfChannels: 1,
                endOfTurnConfidenceThreshold: configuration.endOfTurnConfidenceThreshold,
                inworldSttV1Config: tuning
            ),
            // Raw PCM in binary frames; base64 would make every chunk a third larger.
            audioProtocol: "BINARY"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(message), as: UTF8.self)
    }

    enum ServerMessage: Equatable {
        case event(STTEvent)
        case error(STTServiceError)
        /// Well-formed but nothing this client acts on.
        case ignored
    }

    static func decode(_ text: String) -> ServerMessage {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)) else {
            return .ignored
        }
        if let error = envelope.error {
            return .error(STTServiceError(code: error.code ?? 2, message: error.message ?? ""))
        }
        guard let result = envelope.result else { return .ignored }
        if let transcription = result.transcription {
            // Fields at their default value may be omitted from the JSON.
            let transcript = transcription.transcript ?? ""
            return .event(transcription.isFinal == true ? .final(transcript) : .interim(transcript))
        }
        if result.speechStarted != nil { return .event(.speechStarted) }
        if result.speechStopped != nil { return .event(.speechStopped) }
        if let usage = result.usage {
            return .event(.usage(audioMilliseconds: usage.transcribedAudioMs ?? 0))
        }
        return .ignored
    }

    // MARK: Wire types

    private struct ConfigMessage: Encodable {
        let transcribeConfig: TranscribeConfig
        let audioProtocol: String
    }

    private struct TranscribeConfig: Encodable {
        struct InworldSTTV1Config: Encodable {
            let minEndOfTurnSilenceWhenConfident: Int?
            let maxTurnSilence: Int?
        }

        let modelId: String
        let audioEncoding: String
        let language: String?
        let sampleRateHertz: Int
        let numberOfChannels: Int
        let endOfTurnConfidenceThreshold: Double?
        let inworldSttV1Config: InworldSTTV1Config?
    }

    private struct Envelope: Decodable {
        struct Result: Decodable {
            let transcription: Transcription?
            let usage: Usage?
            let speechStarted: Ignored?
            let speechStopped: Ignored?
        }

        struct Transcription: Decodable {
            let transcript: String?
            let isFinal: Bool?
        }

        struct Usage: Decodable {
            let transcribedAudioMs: Int?
        }

        struct ErrorPayload: Decodable {
            let code: Int?
            let message: String?
        }

        /// Presence is all that matters; the fields are not used.
        struct Ignored: Decodable {}

        let result: Result?
        let error: ErrorPayload?
    }
}
