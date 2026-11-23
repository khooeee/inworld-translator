import Foundation

extension InworldClient {
    // MARK: Wire types

    struct VoicePage: Decodable {
        let voices: [Voice]?
        let nextPageToken: String?
    }

    struct VoicePreview: Decodable {
        let audioContent: Data
    }

    struct ChatRequest: Encodable {
        let model: String
        let models: [String]?
        let messages: [TranslationPrompt.Message]
        let stream: Bool
        let temperature: Double
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, models, messages, stream, temperature
            case maxTokens = "max_tokens"
        }
    }

    struct ChatChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }

            let delta: Delta?
        }

        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }

        struct ErrorPayload: Decodable {
            let message: String?
        }

        let model: String?
        let choices: [Choice]?
        let usage: Usage?
        let error: ErrorPayload?
    }

    struct SpeechRequest: Encodable {
        struct AudioConfig: Encodable {
            let audioEncoding: String
            let sampleRateHertz: Int
            let speakingRate: Double
        }

        let text: String
        let voiceId: String
        let modelId: String
        let language: String
        let audioConfig: AudioConfig
    }

    struct SpeechChunk: Decodable {
        struct Result: Decodable {
            let audioContent: String?
        }

        struct ErrorPayload: Decodable {
            let code: Int?
            let message: String?
        }

        let result: Result?
        let error: ErrorPayload?
    }
}
extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var result = self
        while result.hasSuffix(suffix) { result.removeLast(suffix.count) }
        return result
    }
}

