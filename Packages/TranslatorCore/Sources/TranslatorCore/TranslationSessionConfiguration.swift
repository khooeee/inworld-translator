import Foundation

extension TranslationSession {
    public struct Configuration: Sendable {
        public var stt = STTConfiguration()
        /// Audio kept while disconnected, to send once reconnected. Older
        /// audio is dropped first. 256,000 bytes is 8 seconds.
        public var maxPendingAudioBytes = 256_000
        public var reconnectBaseDelay: Duration = .milliseconds(500)
        public var reconnectMaxDelay: Duration = .seconds(8)
        /// Consecutive failed attempts before the session gives up.
        public var maxReconnectAttempts = 6
        /// A connection that lasted this long resets the attempt count.
        public var stableConnectionInterval: Duration = .seconds(5)
        /// Stop after this long without recognized speech. Inworld bills for
        /// audio sent, not speech detected, so an idle session costs money.
        public var idleTimeout: Duration? = .seconds(180)
        /// Ask the service to finalize a turn that has run this long, so
        /// someone speaking without pauses still gets translated.
        public var maxTurnDuration: Duration? = .seconds(8)
        /// How long Stop waits for the service to finalize the last turn.
        public var finishTimeout: Duration = .seconds(2)
        /// How long Stop waits for translations already under way.
        public var translationDrainTimeout: Duration = .seconds(6)
        /// The longest rate-limit delay the session will wait out by itself.
        public var maxRateLimitWait: Duration = .seconds(15)
        /// How often timers and waits re-check their conditions.
        public var pollInterval: Duration = .milliseconds(100)

        public init() {}
    }
}
