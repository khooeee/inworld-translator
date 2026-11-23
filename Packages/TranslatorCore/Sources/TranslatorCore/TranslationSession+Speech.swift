import Foundation

extension TranslationSession {
    // MARK: - Speech

    /// Records what a settled phrase should say, then hands the speech queue
    /// every phrase at the front of the backlog that is ready.
    func settleSpeech(for phrase: Phrase) {
        guard let index = speechBacklog.firstIndex(where: { $0.id == phrase.id }) else { return }
        speechBacklog[index].settled = true
        speechBacklog[index].language = phrase.targetLanguage
        speechBacklog[index].text = phrase.isSpokenInTargetLanguage ? nil : phrase.translatedText
        while let first = speechBacklog.first, first.settled {
            speechBacklog.removeFirst()
            if let text = first.text {
                speech?.enqueue(id: first.id, text: text, language: first.language)
            }
        }
    }

    func observeSpeech() {
        guard speechObserver == nil, let speech else { return }
        speechObserver = Task { [weak self, events = speech.events] in
            for await event in events {
                await self?.apply(event)
            }
        }
    }

    func apply(_ event: SpeechQueue.Event) {
        switch event {
        case .speaking(let id):
            // Time spent talking is not silence.
            lastActivity = now()
            emit(.speaking(id))
        case .waitingCount(let count):
            emit(.speechQueueDepth(count))
        case .failed:
            guard !speechFailureNoticed else { return }
            speechFailureNoticed = true
            emit(.notice(.speechUnavailable))
        }
    }

    // MARK: - Events out

    func setStatus(_ newStatus: SessionStatus) {
        guard status != newStatus else { return }
        status = newStatus
        emit(.status(newStatus))
    }

    func emit(_ event: SessionEvent) {
        eventContinuation.yield(event)
    }
}
extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
