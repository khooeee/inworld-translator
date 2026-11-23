import Foundation
import TranslatorCore

/// Builds the app's object graph.
///
/// Debug builds accept launch arguments for running in the Simulator against
/// the mock server in tools/mock-inworld, with audio from sample files:
///
///   -InworldBaseURL http://127.0.0.1:8788
///   -InworldAPIKey mock-api-key          use instead of the Keychain
///   -AudioSamplesDirectory /path/to/tools/samples/out
///   -AudioSampleIDs es-name-time,ja-phone
///   -AutoStart YES
///   -SpeaksTranslations YES             speak translations aloud (any build)
@MainActor
struct AppEnvironment {
    let keyStore = APIKeyStore()
    let baseURL: URL
    let client: InworldClient
    let speechVoice: SpeechVoicePreference
    let speechSpeed: SpeechSpeedPreference
    let viewModel: TranslationViewModel
    let autoStart: Bool

    init(defaults: UserDefaults = .standard) {
        #if DEBUG
        let overrides = defaults
        #else
        let overrides = UserDefaults(suiteName: "unused-in-release") ?? defaults
        #endif

        baseURL = overrides.string(forKey: "InworldBaseURL").flatMap(URL.init(string:)) ?? URL(string: "https://api.inworld.ai")!
        autoStart = overrides.bool(forKey: "AutoStart")

        let keyStore = self.keyStore
        let keyOverride = overrides.string(forKey: "InworldAPIKey")
        let apiKey: @Sendable () async -> String? = { keyOverride ?? keyStore.load() }

        let speechVoice = SpeechVoicePreference(defaults: defaults)
        let speechSpeed = SpeechSpeedPreference(defaults: defaults)
        self.speechVoice = speechVoice
        self.speechSpeed = speechSpeed
        client = InworldClient(
            configuration: .init(baseURL: baseURL),
            selectedVoiceID: { await speechVoice.id },
            selectedSpeakingRate: { await speechSpeed.rate },
            apiKey: apiKey
        )
        let audio: any AudioCapturing & SpeechPlaying = Self.sampleAudio(overrides) ?? MicrophoneCapture()
        let session = TranslationSession(
            audio: audio,
            connector: WebSocketSTTConnector(),
            credentials: client,
            translator: client,
            connectivity: PathMonitor(),
            speech: (synthesizer: client, player: audio)
        )
        viewModel = TranslationViewModel(session: session, defaults: defaults) { keyOverride != nil || keyStore.hasKey }
    }

    private static func sampleAudio(_ defaults: UserDefaults) -> PCMFileAudioSource? {
        #if DEBUG
        guard let directory = defaults.string(forKey: "AudioSamplesDirectory") else { return nil }
        let folder = URL(fileURLWithPath: directory)
        let ids = defaults.string(forKey: "AudioSampleIDs")?.split(separator: ",").map(String.init)
            ?? ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                .filter { $0.hasSuffix(".pcm") }
                .map { String($0.dropLast(4)) }
                .sorted()
        let clips = ids.compactMap { id in
            (try? Data(contentsOf: folder.appendingPathComponent("\(id).pcm"))).map { PCMFileAudioSource.Clip(id: id, pcm: $0) }
        }
        return clips.isEmpty ? nil : PCMFileAudioSource(playlist: clips)
        #else
        return nil
        #endif
    }
}

@MainActor
struct SpeechVoicePreference {
    let defaults: UserDefaults
    private static let key = "SpokenTranslationVoiceID"

    var id: InworldClient.Voice.ID {
        defaults.string(forKey: Self.key) ?? InworldClient.Configuration.defaultTTSVoice
    }

    func select(_ id: InworldClient.Voice.ID) {
        defaults.set(id, forKey: Self.key)
    }
}

/// How fast spoken translations are read.
@MainActor
struct SpeechSpeedPreference {
    let defaults: UserDefaults
    private static let key = "SpokenTranslationSpeed"
    private static let range = InworldClient.Configuration.speakingRateRange

    var rate: Double {
        let stored = (defaults.object(forKey: Self.key) as? NSNumber)?.doubleValue
            ?? InworldClient.Configuration.defaultSpeakingRate
        guard stored.isFinite else { return InworldClient.Configuration.defaultSpeakingRate }
        return min(max(stored, Self.range.lowerBound), Self.range.upperBound)
    }

    func select(_ rate: Double) {
        guard rate.isFinite else { return }
        defaults.set(min(max(rate, Self.range.lowerBound), Self.range.upperBound), forKey: Self.key)
    }
}
