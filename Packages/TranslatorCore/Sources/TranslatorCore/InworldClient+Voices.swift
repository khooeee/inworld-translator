import Foundation

extension InworldClient {
    // MARK: Voices

    public func listVoices() async throws -> [Voice] {
        var voices: [Voice.ID: Voice] = [:]
        var nextPage: String?
        var seenPageTokens: Set<String> = []
        let authorization = try await authorization()
        repeat {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "pageSize", value: "100")]
            if let nextPage { query.append(URLQueryItem(name: "pageToken", value: nextPage)) }
            let data = try await voiceData(path: "/voices/v1/voices", query: query, authorization: authorization)
            let page = try JSONDecoder().decode(VoicePage.self, from: data)
            for voice in page.voices ?? [] { voices[voice.id] = voice }
            nextPage = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let nextPage, !seenPageTokens.insert(nextPage).inserted { throw ServiceError.invalidResponse }
        } while nextPage != nil
        return voices.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    public func voicePreview(id: Voice.ID) async throws -> Data {
        let authorization = try await authorization()
        let data = try await voiceData(path: "/tts/v1/voice:preview", query: [
            URLQueryItem(name: "voice_id", value: id),
            URLQueryItem(name: "model_id", value: configuration.ttsModel),
        ], authorization: authorization)
        let preview = try JSONDecoder().decode(VoicePreview.self, from: data)
        guard !preview.audioContent.isEmpty else { throw ServiceError.invalidResponse }
        return preview.audioContent
    }

    func voiceData(path: String, query: [URLQueryItem], authorization: String) async throws -> Data {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw ServiceError.invalidResponse
        }
        components.path = components.path.trimmingSuffix("/") + path
        components.queryItems = query
        // Preserve plus signs in opaque page tokens for form-style query decoders.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ServiceError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard http.statusCode == 200 else { throw Self.error(for: http) }
        return data
    }
}
