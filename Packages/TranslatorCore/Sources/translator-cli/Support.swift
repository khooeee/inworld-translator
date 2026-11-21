import Foundation
import Synchronization
import TranslatorCore

/// Always online; the harness does not simulate network changes.
struct AlwaysOnline: ConnectivityMonitoring {
    func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(true)
        }
    }
}

/// Passes translations through and adds up the tokens they were billed for.
final class MeteredTranslator: Translating {
    private let inner: any Translating
    private let totals = Mutex((prompt: 0, completion: 0, requests: 0, models: [String: Int]()))

    init(_ inner: any Translating) {
        self.inner = inner
    }

    var usage: (prompt: Int, completion: Int, requests: Int, models: [String: Int]) {
        totals.withLock { $0 }
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationUpdate, Error> {
        let upstream = inner.translate(request)
        totals.withLock { $0.requests += 1 }
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    for try await update in upstream {
                        if case .usage(let prompt, let completion, let model) = update {
                            self.totals.withLock {
                                $0.prompt += prompt
                                $0.completion += completion
                                if let model { $0.models[model, default: 0] += 1 }
                            }
                        }
                        continuation.yield(update)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Passes speech through and records how much was asked for and how long the
/// audio took to start.
final class MeteredSynthesizer: SpeechSynthesizing {
    private let inner: any SpeechSynthesizing
    private let totals = Mutex((requests: 0, failures: 0, characters: 0, firstAudio: [Double]()))

    init(_ inner: any SpeechSynthesizing) {
        self.inner = inner
    }

    var usage: (requests: Int, failures: Int, characters: Int, firstAudio: [Double]) {
        totals.withLock { $0 }
    }

    func synthesize(_ text: String) -> AsyncThrowingStream<Data, Error> {
        let upstream = inner.synthesize(text)
        let requestedAt = Date()
        totals.withLock {
            $0.requests += 1
            $0.characters += text.count
        }
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    var started = false
                    for try await chunk in upstream {
                        if !started {
                            started = true
                            self.totals.withLock { $0.firstAudio.append(Date().timeIntervalSince(requestedAt)) }
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        self.totals.withLock { $0.failures += 1 }
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
