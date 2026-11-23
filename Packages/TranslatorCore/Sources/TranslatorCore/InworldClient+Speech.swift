import Foundation

extension InworldClient {
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

    func runSynthesis(_ text: String, language: TargetLanguage, yield: @Sendable (Data) -> Void) async throws {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.utf16.count > Self.maxSpeechLength {
            text.removeLast()
        }
        guard !text.isEmpty else { return }

        let voiceID = await selectedVoiceID() ?? configuration.ttsVoice
        let speakingRate = Self.clampedSpeakingRate(await selectedSpeakingRate())
        var request = URLRequest(url: configuration.ttsStreamURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            SpeechRequest(
                text: text,
                voiceId: voiceID,
                modelId: configuration.ttsModel,
                language: language.rawValue,
                // PCM is headerless; LINEAR16 would put a WAV header on every chunk.
                audioConfig: .init(
                    audioEncoding: "PCM",
                    sampleRateHertz: SpeechAudio.sampleRate,
                    // The service takes the speed inside audioConfig, not on the request.
                    speakingRate: speakingRate
                )
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

    /// Keeps a requested speed inside the range the service accepts.
    static func clampedSpeakingRate(_ rate: Double) -> Double {
        guard rate.isFinite else { return Configuration.defaultSpeakingRate }
        return min(max(rate, Configuration.speakingRateRange.lowerBound), Configuration.speakingRateRange.upperBound)
    }

    /// Maps an in-band error's gRPC status code.
    static func error(forStatusCode code: Int?) -> ServiceError {
        switch code {
        case 7, 16: .unauthorized // PERMISSION_DENIED, UNAUTHENTICATED
        case 8: .rateLimited(retryAfter: nil) // RESOURCE_EXHAUSTED
        default: .server(status: 502)
        }
    }

    static func error(for response: HTTPURLResponse) -> ServiceError {
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

    static func normalize(_ error: Error) -> Error {
        if error is ServiceError || error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        return ServiceError.transport
    }
}
