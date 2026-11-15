import Network
import TranslatorCore

/// Reports whether the network is usable, from `NWPathMonitor`.
struct PathMonitor: ConnectivityMonitoring {
    func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "PathMonitor"))
        }
    }
}
