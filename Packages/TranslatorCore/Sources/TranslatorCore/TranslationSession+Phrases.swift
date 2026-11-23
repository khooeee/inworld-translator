import Foundation

extension TranslationSession {
    // MARK: - Results in

    func handle(_ event: STTEvent, connectionID id: Int, runID: Int, languages: Languages) async {
        // Results from a connection that has been replaced are stale.
        guard id == connectionID else { return }
        switch event {
        case .interim(let text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            lastActivity = now()
            if var phrase = current {
                guard phrase.sourceText != text else { return }
                phrase.sourceText = text
                current = phrase
                emit(.phrase(phrase))
            } else {
                let phrase = Phrase(
                    id: makePhraseID(),
                    sourceText: text,
                    languageCode: languages.fixedSourceCode,
                    targetLanguage: languages.target,
                    timing: PhraseTiming(startedAt: now())
                )
                current = phrase
                turnStartedAt = now()
                endTurnRequested = false
                emit(.phrase(phrase))
            }
        case .final(let text):
            lastActivity = now()
            await commit(text: text, as: .final, languages: languages, runID: runID)
        case .speechStarted, .speechStopped, .usage:
            break
        }
    }

    /// Commits the open phrase with its last provisional text, when no final
    /// result is going to arrive for it.
    func commitCurrentPhrase(as state: Phrase.SourceState, languages: Languages, runID: Int? = nil) async {
        guard let current else { return }
        await commit(text: current.sourceText, as: state, languages: languages, runID: runID)
    }

    /// Ends the current turn: the phrase becomes final and is queued for
    /// translation, exactly once.
    func commit(text: String, as state: Phrase.SourceState, languages: Languages, runID: Int?) async {
        let existing = current
        current = nil
        turnStartedAt = nil
        endTurnRequested = false

        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.containsSpeech(text) else {
            // Noise can produce an interim that the final then retracts.
            if let existing {
                emit(.removed(existing.id))
            }
            return
        }

        let timestamp = now()
        var phrase = existing ?? Phrase(
            id: makePhraseID(),
            sourceText: text,
            languageCode: languages.fixedSourceCode,
            targetLanguage: languages.target,
            timing: PhraseTiming(startedAt: timestamp)
        )
        phrase.sourceText = text
        phrase.sourceState = state
        phrase.translation = .pending
        phrase.timing.finalizedAt = timestamp
        translating[phrase.id] = phrase
        if speaksTranslations, let runID, isCurrent(runID), !suspended {
            speechBacklog.append(SpeechSlot(id: phrase.id, language: phrase.targetLanguage))
        }
        emit(.phrase(phrase))
        await pipeline.submit(
            id: phrase.id,
            text: text,
            sourceLanguage: languages.source,
            targetLanguage: languages.target,
            bidirectional: languages.bidirectional
        )
    }

    func makePhraseID() -> PhraseID {
        defer { nextPhraseID += 1 }
        return PhraseID(nextPhraseID)
    }

    /// Whether the text has any letters or digits, as opposed to being empty
    /// or only punctuation.
    static func containsSpeech(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    // MARK: - Translations in

    func observeTranslations() {
        guard translationObserver == nil else { return }
        translationObserver = Task { [weak self, updates = pipeline.updates] in
            for await update in updates {
                await self?.apply(update)
            }
        }
    }

    func apply(_ update: TranslationPipeline.Update) {
        // A settled phrase is no longer tracked, so nothing can change it again.
        guard var phrase = translating[update.id] else { return }
        switch update.kind {
        case .pending:
            guard phrase.translation != .pending else { return }
            phrase.translation = .pending
        case .language(let code, let target):
            phrase.languageCode = code
            phrase.targetLanguage = target ?? phrase.targetLanguage
        case .partial(let text):
            if phrase.timing.translationStartedAt == nil {
                phrase.timing.translationStartedAt = now()
            }
            phrase.translation = .partial(text)
        case .completed(let text, let language, let target):
            let timestamp = now()
            phrase.timing.translationStartedAt = phrase.timing.translationStartedAt ?? timestamp
            phrase.timing.translationCompletedAt = timestamp
            phrase.languageCode = language ?? phrase.languageCode
            phrase.targetLanguage = target ?? phrase.targetLanguage
            phrase.translation = .completed(text)
        case .unavailable(let reason, let error):
            phrase.translation = .unavailable(reason)
            noteTranslationFailure(error)
        }
        translating[phrase.id] = phrase.isSettled ? nil : phrase
        emit(.phrase(phrase))
        if phrase.isSettled {
            settleSpeech(for: phrase)
        }
    }

    func noteTranslationFailure(_ error: ServiceError?) {
        switch error {
        case .unauthorized:
            if let run {
                beginStop(runID: run.id, notice: .unauthorized)
            }
        case .rateLimited, .quotaExceeded:
            if !translationLimitNoticed {
                translationLimitNoticed = true
                emit(.notice(.translationLimited))
            }
        default:
            break
        }
    }
}
