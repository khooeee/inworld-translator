import Foundation

extension TranslationSession {
    // MARK: - Audio out

    func pumpAudio(_ chunks: AsyncStream<AudioChunk>, runID: Int) async {
        for await chunk in chunks {
            if isCurrent(runID), !suspended {
                emit(.level(chunk.level))
            }
            await forward(chunk.pcm)
        }
        guard !Task.isCancelled else { return }
        // Capture ended on its own, which only happens on stop. Close the
        // stream properly so the service finalizes the last turn.
        if let connection {
            _ = await sendPendingAudio(to: connection)
            await connection.finish(timeout: configuration.finishTimeout)
        }
    }

    /// Sends one chunk, or holds it while there is no connection. This is the
    /// only place audio is sent, and the pump awaits each send, so order is
    /// kept and a slow socket pushes back on the capture stream's bounded
    /// buffer instead of growing a queue here.
    func forward(_ pcm: Data) async {
        guard !suspended else { return }
        guard let connection else {
            hold(pcm)
            return
        }
        guard await sendPendingAudio(to: connection) else {
            hold(pcm)
            return
        }
        do {
            try await connection.send(audio: pcm)
        } catch {
            // The socket is failing. Close it so the supervisor reconnects,
            // and keep the chunk for the next connection.
            hold(pcm)
            connection.cancel()
        }
    }

    /// Sends audio held while disconnected. Returns false if the socket failed.
    func sendPendingAudio(to connection: any STTConnection) async -> Bool {
        while !pendingAudio.isEmpty {
            let chunk = pendingAudio.removeFirst()
            pendingAudioBytes -= chunk.count
            do {
                try await connection.send(audio: chunk)
            } catch {
                pendingAudio.insert(chunk, at: 0)
                pendingAudioBytes += chunk.count
                connection.cancel()
                return false
            }
        }
        return true
    }

    func hold(_ pcm: Data) {
        pendingAudio.append(pcm)
        pendingAudioBytes += pcm.count
        while pendingAudioBytes > configuration.maxPendingAudioBytes, !pendingAudio.isEmpty {
            pendingAudioBytes -= pendingAudio.removeFirst().count
        }
    }

    // MARK: - Connection

    enum ConnectFailure {
        case retry
        case retryAfter(Duration)
        case stop(SessionNotice)
    }

    /// Keeps one STT connection open for the life of the run, reconnecting
    /// with exponential backoff when it drops.
    func superviseConnection(runID: Int, languages: Languages) async {
        var stt = configuration.stt
        stt.languageHint = languages.bidirectional ? nil : (languages.source ?? stt.languageHint)
        var attempt = 0
        while isCurrent(runID), !Task.isCancelled {
            if suspended {
                attempt = 0
                try? await Task.sleep(for: configuration.pollInterval)
                continue
            }
            if !networkAvailable {
                attempt = 0
                setStatus(.waitingForNetwork)
                try? await Task.sleep(for: configuration.pollInterval)
                continue
            }
            setStatus(hasConnected ? .reconnecting : .starting)

            var delay: Duration?
            do {
                let credential = try await credentials.sttCredential()
                let connection = try await connector.connect(credential: credential, configuration: stt)
                guard isCurrent(runID), !Task.isCancelled, !suspended else {
                    connection.cancel()
                    continue
                }

                connectionID += 1
                let id = connectionID
                self.connection = connection
                hasConnected = true
                lastActivity = now()
                let connectedAt = now()
                setStatus(.listening)

                let failure = await receive(from: connection, id: id, runID: runID, languages: languages)

                if connectionID == id {
                    self.connection = nil
                }
                // Whatever was on screen for the open turn is all there will be.
                await commitCurrentPhrase(as: .interrupted, languages: languages, runID: runID)
                guard isCurrent(runID), !Task.isCancelled else { return }

                // The same key and the same request would be rejected again.
                if let serviceError = failure as? STTServiceError {
                    if serviceError.isAuthentication {
                        beginStop(runID: runID, notice: .unauthorized)
                        return
                    }
                    if serviceError.isInvalidArgument {
                        beginStop(runID: runID, notice: .serviceRejectedRequest)
                        return
                    }
                }
                if suspended || !networkAvailable { continue }
                if now().timeIntervalSince(connectedAt) >= configuration.stableConnectionInterval.timeInterval {
                    attempt = 0
                }
            } catch {
                guard isCurrent(runID), !Task.isCancelled else { return }
                switch classify(error) {
                case .retry:
                    break
                case .retryAfter(let wait):
                    delay = wait
                case .stop(let notice):
                    beginStop(runID: runID, notice: notice)
                    return
                }
            }

            attempt += 1
            if attempt > configuration.maxReconnectAttempts {
                beginStop(runID: runID, notice: .connectionFailed)
                return
            }
            setStatus(hasConnected ? .reconnecting : .starting)
            await backOff(delay ?? backoffDelay(attempt: attempt), runID: runID)
        }
    }

    func classify(_ error: Error) -> ConnectFailure {
        guard let serviceError = error as? ServiceError else { return .retry }
        switch serviceError {
        case .unauthorized:
            return .stop(.unauthorized)
        case .notConfigured:
            return .stop(.notConfigured)
        case .quotaExceeded:
            return .stop(.usageLimitReached(retryAfter: nil))
        case .rateLimited(let retryAfter):
            // A short wait is absorbed; a long one is the user's to decide.
            if let retryAfter, retryAfter <= configuration.maxRateLimitWait.timeInterval {
                return .retryAfter(.milliseconds(Int(retryAfter * 1000) + 250))
            }
            return .stop(.usageLimitReached(retryAfter: retryAfter))
        case .server, .transport, .invalidResponse:
            return .retry
        }
    }

    func backoffDelay(attempt: Int) -> Duration {
        let base = configuration.reconnectBaseDelay.timeInterval
        let ceiling = configuration.reconnectMaxDelay.timeInterval
        let exponential = min(ceiling, base * pow(2, Double(attempt - 1)))
        // Jitter keeps many clients from reconnecting in step after an outage.
        return .milliseconds(Int(exponential * Double.random(in: 0.75...1.0) * 1000))
    }

    /// Waits out a backoff, returning early if the network comes back or the
    /// run changes state.
    func backOff(_ delay: Duration, runID: Int) async {
        let deadline = now().addingTimeInterval(delay.timeInterval)
        let epoch = networkEpoch
        while isCurrent(runID), !Task.isCancelled, !suspended, networkEpoch == epoch, now() < deadline {
            try? await Task.sleep(for: min(configuration.pollInterval, delay))
        }
    }

    /// Handles results until the connection ends. Returns the error it ended
    /// with, or nil for a clean close.
    func receive(from connection: any STTConnection, id: Int, runID: Int, languages: Languages) async -> Error? {
        do {
            for try await event in connection.events {
                await handle(event, connectionID: id, runID: runID, languages: languages)
            }
            return nil
        } catch {
            return error
        }
    }

    func networkChanged(_ available: Bool, runID: Int) {
        guard isCurrent(runID), available != networkAvailable else { return }
        networkAvailable = available
        if available {
            networkEpoch += 1
        } else {
            // A socket on a dead network can take a long time to notice.
            connection?.cancel()
        }
    }

    func handleCapture(_ event: AudioCaptureEvent, runID: Int) {
        guard isCurrent(runID) else { return }
        switch event {
        case .interruptionBegan:
            guard !suspended else { return }
            suspended = true
            pendingAudio.removeAll()
            pendingAudioBytes = 0
            // Whatever was waiting to be said is stale by the time a call ends.
            speechBacklog.removeAll()
            speech?.cancelAll()
            setStatus(.interrupted)
            emit(.level(0))
            // The supervisor sees the close, commits the open phrase, and waits.
            connection?.cancel()
        case .interruptionEnded(let resumed):
            guard suspended else { return }
            if resumed {
                suspended = false
                lastActivity = now()
            } else {
                beginStop(runID: runID, notice: .stoppedByInterruption)
            }
        case .failed:
            beginStop(runID: runID, notice: .microphoneUnavailable)
        }
    }

    func watchTimers(runID: Int) async {
        while isCurrent(runID), !Task.isCancelled {
            try? await Task.sleep(for: configuration.pollInterval)
            guard isCurrent(runID), status == .listening else { continue }
            let now = now()

            if let idleTimeout = configuration.idleTimeout,
               now.timeIntervalSince(lastActivity) > idleTimeout.timeInterval {
                beginStop(runID: runID, notice: .stoppedAfterSilence)
                return
            }
            if let maxTurnDuration = configuration.maxTurnDuration,
               let turnStartedAt, !endTurnRequested,
               now.timeIntervalSince(turnStartedAt) > maxTurnDuration.timeInterval,
               let connection {
                endTurnRequested = true
                try? await connection.endTurn()
            }
        }
    }
}
