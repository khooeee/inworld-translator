import Foundation

/// Talks to the app's backend, which holds the Inworld API key. The backend
/// mints single-use STT credentials and performs translations; this client
/// only ever holds the app's own client key.
public actor BackendClient: CredentialProviding, Translating {
    public struct Configuration: Sendable, Equatable {
        public let baseURL: URL
        public let clientKey: String

        public init(baseURL: URL, clientKey: String) {
            self.baseURL = baseURL
            self.clientKey = clientKey
        }
    }

    private enum Route: String {
        case token = "v1/stt/token"
        case translate = "v1/translate"
    }

    private let configuration: Configuration
    private let session: URLSession
    private let now: @Sendable () -> Date
    /// Until when the backend asked this client not to call a route again.
    private var blockedUntil: [Route: (date: Date, error: BackendError)] = [:]

    public init(
        configuration: Configuration,
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.now = now
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 15
            sessionConfiguration.waitsForConnectivity = false
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    // MARK: CredentialProviding

    public func sttCredential() async throws -> STTCredential {
        let request = try makeRequest(.token, body: Data("{}".utf8))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.normalize(error)
        }
        try check(response, body: data, route: .token)

        guard
            let payload = try? JSONDecoder().decode(TokenResponse.self, from: data),
            let expiresAt = Self.parseTimestamp(payload.expireTime),
            let url = URL(string: payload.websocketURL),
            let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
            !payload.accessToken.isEmpty
        else {
            throw BackendError.invalidResponse
        }
        return STTCredential(
            accessToken: payload.accessToken,
            expiresAt: expiresAt,
            websocketURL: url,
            modelID: payload.modelId
        )
    }

    // MARK: Translating

    public nonisolated func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationUpdate, Error> {
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
        let body = try JSONEncoder().encode(TranslateBody(text: translation.text, context: translation.context))
        var request = try makeRequest(.translate, body: body)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            // Errors before the stream starts arrive as a small JSON body.
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 4096 { break }
            }
            try check(response, body: body, route: .translate)
            throw BackendError.invalidResponse
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = Data(line.dropFirst("data:".count).utf8)
            guard let event = try? JSONDecoder().decode(TranslateEvent.self, from: payload) else { continue }
            switch event.type {
            case "language":
                if let code = event.code { yield(.language(code)) }
            case "delta":
                if let text = event.text, !text.isEmpty { yield(.delta(text)) }
            case "done":
                yield(.completed(translation: event.translation ?? "", language: event.language))
                return
            case "error":
                throw BackendError.server(status: 502)
            default:
                continue
            }
        }
        // The stream ended without a terminal event.
        throw BackendError.invalidResponse
    }

    // MARK: Requests and responses

    private func makeRequest(_ route: Route, body: Data) throws -> URLRequest {
        if let block = blockedUntil[route] {
            if block.date > now() { throw block.error }
            blockedUntil[route] = nil
        }
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(route.rawValue))
        request.httpMethod = "POST"
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.clientKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Throws the `BackendError` for a non-success response.
    private func check(_ response: URLResponse, body: Data, route: Route) throws {
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        switch http.statusCode {
        case 200:
            return
        case 401, 403:
            throw BackendError.unauthorized
        case 429:
            let payload = try? JSONDecoder().decode(ErrorResponse.self, from: body)
            let retryAfter = payload?.error.retryAfterSeconds
                ?? http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let error: BackendError = payload?.error.code == "quota_exceeded"
                ? .quotaExceeded(retryAfter: retryAfter)
                : .rateLimited(retryAfter: retryAfter)
            // Honor the backend's request to wait instead of asking again.
            if let retryAfter, retryAfter > 0 {
                blockedUntil[route] = (now().addingTimeInterval(retryAfter), error)
            }
            throw error
        default:
            throw BackendError.server(status: http.statusCode)
        }
    }

    private static func normalize(_ error: Error) -> Error {
        if error is BackendError || error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        return BackendError.transport
    }

    static func parseTimestamp(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    // MARK: Wire types

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expireTime: String
        let websocketURL: String
        let modelId: String
    }

    private struct TranslateBody: Encodable {
        let text: String
        let context: [TranslationContextItem]
    }

    private struct TranslateEvent: Decodable {
        let type: String
        let code: String?
        let text: String?
        let translation: String?
        let language: String?
    }

    private struct ErrorResponse: Decodable {
        struct Payload: Decodable {
            let code: String
            let retryAfterSeconds: TimeInterval?
        }

        let error: Payload
    }
}
