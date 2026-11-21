import Foundation

/// Talks to the Inworld API directly with the user's API key: credentials for
/// the STT socket, translations through chat completions, and speech through
/// streaming TTS.
///
/// The key is read through `apiKey` on every use, so a key saved or changed
/// in Settings takes effect on the next connection or request.
public struct InworldClient: CredentialProviding, Translating, SpeechSynthesizing {
    public struct Configuration: Sendable, Equatable {
        public var baseURL: URL
        public var sttModel: String
        public var translationModel: String
        /// Tried in order if the main model fails before answering.
        public var translationFallbackModels: [String]
        public var ttsModel: String
        public var ttsVoice: String

        public init(
            baseURL: URL = URL(string: "https://api.inworld.ai")!,
            sttModel: String = "inworld/inworld-stt-1",
            translationModel: String = "google-ai-studio/gemini-2.5-flash-lite",
            translationFallbackModels: [String] = ["openai/gpt-4o-mini"],
            ttsModel: String = "inworld-tts-2-flash",
            ttsVoice: String = "Ashley"
        ) {
            self.baseURL = baseURL
            self.sttModel = sttModel
            self.translationModel = translationModel
            self.translationFallbackModels = translationFallbackModels
            self.ttsModel = ttsModel
            self.ttsVoice = ttsVoice
        }

        var sttWebSocketURL: URL {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            components.scheme = components.scheme == "http" ? "ws" : "wss"
            components.path = components.path.trimmingSuffix("/") + "/stt/v1/transcribe:streamBidirectional"
            return components.url!
        }

        var chatCompletionsURL: URL {
            baseURL.appendingPathComponent("v1/chat/completions")
        }

        var ttsStreamURL: URL {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            components.path = components.path.trimmingSuffix("/") + "/tts/v1/voice:stream"
            return components.url!
        }
    }

    /// The longest text one streaming TTS request accepts, in UTF-16 units.
    static let maxSpeechLength = 4000

    private let configuration: Configuration
    private let apiKey: @Sendable () async -> String?
    private let session: URLSession

    public init(
        configuration: Configuration = Configuration(),
        session: URLSession? = nil,
        apiKey: @escaping @Sendable () async -> String?
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 15
            sessionConfiguration.waitsForConnectivity = false
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    /// The Portal's Base64 credential, used as-is: it is already encoded.
    private func authorization() async throws -> String {
        guard let key = await apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ServiceError.notConfigured
        }
        return "Basic \(key)"
    }

    // MARK: CredentialProviding

    public func sttCredential() async throws -> STTCredential {
        STTCredential(
            authorization: try await authorization(),
            websocketURL: configuration.sttWebSocketURL,
            modelID: configuration.sttModel
        )
    }

    // MARK: Translating

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runTranslation(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runTranslation(
        _ translation: TranslationRequest,
        yield: @Sendable (TranslationUpdate) -> Void
    ) async throws {
        var request = URLRequest(url: configuration.chatCompletionsURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: configuration.translationModel,
                models: configuration.translationFallbackModels.isEmpty ? nil : configuration.translationFallbackModels,
                messages: TranslationPrompt.messages(for: translation),
                stream: true,
                temperature: 0,
                maxTokens: TranslationPrompt.maxOutputTokens(for: translation.text)
            )
        )

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        // Failures before the first chunk arrive as a normal HTTP error.
        guard http.statusCode == 200 else { throw Self.error(for: http) }

        var parser = TranslationReplyParser()
        var languageSent = false
        func forward(_ text: String) {
            if let language = parser.language, !languageSent {
                languageSent = true
                yield(.language(language))
            }
            if !text.isEmpty { yield(.delta(text)) }
        }

        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" {
                forward(parser.end())
                yield(.completed(translation: parser.translation, language: parser.language))
                return
            }
            guard let chunk = try? decoder.decode(ChatChunk.self, from: Data(data.utf8)) else { continue }
            // After the first chunk, the router reports failures in-band.
            if chunk.error != nil { throw ServiceError.server(status: 502) }
            if let usage = chunk.usage {
                yield(.usage(promptTokens: usage.promptTokens ?? 0, completionTokens: usage.completionTokens ?? 0, model: chunk.model))
            }
            forward(parser.push(chunk.choices?.first?.delta?.content ?? ""))
        }
        // A stream that stops without [DONE] is a failed request.
        throw ServiceError.invalidResponse
    }

    // MARK: SpeechSynthesizing

    public func synthesize(_ text: String, language: TargetLanguage) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runSynthesis(text, language: language) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runSynthesis(_ text: String, language: TargetLanguage, yield: @Sendable (Data) -> Void) async throws {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.utf16.count > Self.maxSpeechLength {
            text.removeLast()
        }
        guard !text.isEmpty else { return }

        var request = URLRequest(url: configuration.ttsStreamURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            SpeechRequest(
                text: text,
                voiceId: configuration.ttsVoice,
                modelId: configuration.ttsModel,
                language: language.rawValue,
                // PCM is headerless; LINEAR16 would put a WAV header on every chunk.
                audioConfig: .init(audioEncoding: "PCM", sampleRateHertz: SpeechAudio.sampleRate)
            )
        )

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard http.statusCode == 200 else { throw Self.error(for: http) }

        // One JSON object per line, each with a piece of the audio.
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard let chunk = try? decoder.decode(SpeechChunk.self, from: Data(line.utf8)) else { continue }
            // Failures after the response has started arrive in-band.
            if let error = chunk.error { throw Self.error(forStatusCode: error.code) }
            if let audio = chunk.result?.audioContent.flatMap({ Data(base64Encoded: $0) }), !audio.isEmpty {
                yield(audio)
            }
        }
    }

    /// Maps an in-band error's gRPC status code.
    private static func error(forStatusCode code: Int?) -> ServiceError {
        switch code {
        case 7, 16: .unauthorized // PERMISSION_DENIED, UNAUTHENTICATED
        case 8: .rateLimited(retryAfter: nil) // RESOURCE_EXHAUSTED
        default: .server(status: 502)
        }
    }

    private static func error(for response: HTTPURLResponse) -> ServiceError {
        switch response.statusCode {
        case 401, 403:
            return .unauthorized
        case 402:
            return .quotaExceeded
        case 429:
            return .rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default:
            return .server(status: response.statusCode)
        }
    }

    private static func normalize(_ error: Error) -> Error {
        if error is ServiceError || error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        return ServiceError.transport
    }

    // MARK: Wire types

    private struct ChatRequest: Encodable {
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

    private struct ChatChunk: Decodable {
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

    private struct SpeechRequest: Encodable {
        struct AudioConfig: Encodable {
            let audioEncoding: String
            let sampleRateHertz: Int
        }

        let text: String
        let voiceId: String
        let modelId: String
        let language: String
        let audioConfig: AudioConfig
    }

    private struct SpeechChunk: Decodable {
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

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var result = self
        while result.hasSuffix(suffix) { result.removeLast(suffix.count) }
        return result
    }
}
