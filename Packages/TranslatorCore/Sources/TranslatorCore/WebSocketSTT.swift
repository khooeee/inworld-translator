import Foundation

/// Opens Inworld STT connections with `URLSessionWebSocketTask`.
public struct WebSocketSTTConnector: STTConnecting {
    private let session: URLSession
    private let openTimeout: Duration

    public init(session: URLSession = URLSession(configuration: .ephemeral), openTimeout: Duration = .seconds(10)) {
        self.session = session
        self.openTimeout = openTimeout
    }

    public func connect(
        credential: STTCredential,
        configuration: STTConfiguration
    ) async throws -> any STTConnection {
        let config = try STTWire.configMessage(modelID: credential.modelID, configuration: configuration)

        // The key goes in a header, never in the URL, where it would be logged.
        var request = URLRequest(url: credential.websocketURL)
        request.setValue(credential.authorization, forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()

        // The send completes once the socket is open and the config is
        // written, so it doubles as the signal that the handshake succeeded.
        // A stuck handshake is cut by the watchdog; cancelling the caller
        // cuts it too.
        let watchdog = Task { [openTimeout] in
            try await Task.sleep(for: openTimeout)
            task.cancel()
        }
        defer { watchdog.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await task.send(.string(config))
            } onCancel: {
                task.cancel()
            }
        } catch {
            task.cancel()
            if Task.isCancelled { throw CancellationError() }
            throw STTConnectionError.connectFailed
        }
        return WebSocketSTTConnection(task: task)
    }
}

final class WebSocketSTTConnection: STTConnection {
    let events: AsyncThrowingStream<STTEvent, Error>
    private let task: URLSessionWebSocketTask
    private let receiver: Task<Void, Never>

    init(task: URLSessionWebSocketTask) {
        self.task = task
        let (events, continuation) = AsyncThrowingStream<STTEvent, Error>.makeStream()
        self.events = events
        self.receiver = Task {
            do {
                while true {
                    let text: String
                    switch try await task.receive() {
                    case .string(let string): text = string
                    case .data(let data): text = String(decoding: data, as: UTF8.self)
                    @unknown default: continue
                    }
                    switch STTWire.decode(text) {
                    case .event(let event):
                        continuation.yield(event)
                    case .error(let error):
                        // The service closes after an error frame; do not wait for it.
                        continuation.finish(throwing: error)
                        task.cancel(with: .normalClosure, reason: nil)
                        return
                    case .ignored:
                        break
                    }
                }
            } catch {
                if task.closeCode == .normalClosure {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: STTConnectionError.disconnected)
                }
            }
        }
        // If the consumer goes away, stop the socket.
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel(with: .goingAway, reason: nil) }
        }
    }

    func send(audio: Data) async throws {
        try await task.send(.data(audio))
    }

    func endTurn() async throws {
        try await task.send(.string(STTWire.endTurn))
    }

    func finish(timeout: Duration) async {
        // After closeStream the service finalizes pending audio, reports
        // usage, and closes. Results keep flowing through `events` meanwhile.
        try? await task.send(.string(STTWire.closeStream))
        _ = await receiver.value(within: timeout)
        task.cancel(with: .normalClosure, reason: nil)
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
