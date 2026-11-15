import Foundation

struct TimeoutError: Error {}

/// Runs `operation`, cancelling it and throwing `TimeoutError` if it takes
/// longer than `duration`. The operation must respond to cancellation.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

extension Task where Failure == Never, Success: Sendable {
    /// Waits for the task for at most `timeout`. Returns nil if it has not
    /// finished by then, or if the caller is cancelled first. The task itself
    /// is left running.
    func value(within timeout: Duration) async -> Success? {
        let (results, continuation) = AsyncStream<Success?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let waiter = Task<Void, Never> {
            continuation.yield(await self.value)
            continuation.finish()
        }
        let timer = Task<Void, Never> {
            try? await Task<Never, Never>.sleep(for: timeout)
            continuation.yield(nil)
            continuation.finish()
        }
        defer {
            waiter.cancel()
            timer.cancel()
        }
        for await result in results { return result }
        return nil
    }
}
