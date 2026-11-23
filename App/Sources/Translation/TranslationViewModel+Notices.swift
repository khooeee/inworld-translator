import Foundation
import TranslatorCore

extension TranslationViewModel {
    struct Notice: Equatable {
        enum Action: Equatable {
            case openSystemSettings
            case openAPIKeySettings
        }

        let message: String
        let action: Action?
    }

    struct PhraseChanges: Equatable {
        var inserted: [PhraseID] = []
        var updated: [PhraseID] = []
        var removed: [PhraseID] = []
    }


    static func notice(for notice: SessionNotice) -> Notice {
        switch notice {
        case .microphoneDenied:
            Notice(message: String(localized: "Microphone access is off. Turn it on in Settings to translate."), action: .openSystemSettings)
        case .microphoneUnavailable:
            Notice(message: String(localized: "The microphone isn't available right now."), action: nil)
        case .notConfigured:
            Notice(message: String(localized: "Add your Inworld API key to start translating."), action: .openAPIKeySettings)
        case .unauthorized:
            Notice(message: String(localized: "Inworld didn't accept the API key. Check it in Settings."), action: .openAPIKeySettings)
        case .usageLimitReached(let retryAfter):
            if let retryAfter, retryAfter < 3600 {
                Notice(message: String(localized: "Inworld's rate limit was reached. Try again in \(Int(retryAfter.rounded(.up))) seconds."), action: nil)
            } else {
                Notice(message: String(localized: "Your Inworld usage limit or credits ran out."), action: nil)
            }
        case .connectionFailed:
            Notice(message: String(localized: "Couldn't reach Inworld. Check your connection and try again."), action: nil)
        case .serviceRejectedRequest:
            Notice(message: String(localized: "Inworld rejected the audio settings. Listening stopped."), action: nil)
        case .stoppedAfterSilence:
            Notice(message: String(localized: "Stopped after a few minutes without speech."), action: nil)
        case .stoppedInBackground:
            Notice(message: String(localized: "Stopped because the app left the screen."), action: nil)
        case .stoppedByInterruption:
            Notice(message: String(localized: "Stopped because another app used the microphone."), action: nil)
        case .translationLimited:
            Notice(message: String(localized: "Inworld is limiting translations. Some phrases won't be translated."), action: nil)
        case .speechUnavailable:
            Notice(message: String(localized: "Couldn't read the translation aloud. Captions will continue."), action: nil)
        }
    }
}
