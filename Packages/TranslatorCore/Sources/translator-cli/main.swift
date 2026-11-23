// Runs the app's translation pipeline end to end, outside the app: real
// TranslationSession, WebSocket STT client and Inworld client, with audio
// from files instead of the microphone. Reports recognition accuracy,
// language detection, latency, cost, reconnects and memory.
//
//   INWORLD_API_KEY=... swift run translator-cli tools/samples/manifest.json
//
// Options:
//   --base-url URL      Inworld API base (default https://api.inworld.ai);
//                       point it at tools/mock-inworld for a run without a key
//   --speed X           playback speed; 1 is real time (default 1)
//   --loops N           play the whole manifest N times in one session (default 1)
//   --only a,b          play only these sample IDs
//   --drop-every SECS   cut the STT connection this often (mock server only)
//   --model ID          translation model
//   --speak             also turn each translation into speech with Inworld
//                       TTS (not played out loud) and report how long the
//                       audio takes to start. Clips wait while speech "plays",
//                       so the run takes longer.
//   --speaking-rate X   speed of spoken translations, 0.5–1.5 (default 1)
//   --report PATH       also write the report as JSON
//   --stt-price X       USD per hour of audio (default 0.15, On-Demand)
//   --input-price X     USD per million input tokens (default 0.10)
//   --output-price X    USD per million output tokens (default 0.40)
//   --tts-price X       USD per million characters spoken (default 15)

import Darwin
import Foundation
import TranslatorCore

// MARK: - Run

let options = Options.parse(CommandLine.arguments)
guard let apiKey = ProcessInfo.processInfo.environment["INWORLD_API_KEY"], !apiKey.isEmpty else {
    fail("set INWORLD_API_KEY (any value works with the mock server)")
}

let manifest: Manifest
do {
    manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: options.manifest))
} catch {
    fail("cannot read \(options.manifest.path): \(error)")
}
let audioDirectory = options.manifest.deletingLastPathComponent().appendingPathComponent("out")
let samples = manifest.samples.filter { options.only?.contains($0.id) ?? true }
var clips: [PCMFileAudioSource.Clip] = []
for _ in 0..<max(1, options.loops) {
    for sample in samples {
        let url = audioDirectory.appendingPathComponent("\(sample.id).pcm")
        guard let pcm = try? Data(contentsOf: url) else {
            fail("missing \(url.path); run python3 -I tools/samples/make_samples.py")
        }
        clips.append(.init(id: sample.id, pcm: pcm))
    }
}
let samplesByID = Dictionary(manifest.samples.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

var clientConfiguration = InworldClient.Configuration(baseURL: options.baseURL)
if let model = options.model { clientConfiguration.translationModel = model }
let speakingRate = options.speakingRate
let client = InworldClient(configuration: clientConfiguration, selectedSpeakingRate: { speakingRate }) { apiKey }
let translator = MeteredTranslator(client)
let synthesizer = MeteredSynthesizer(client)
let audio = PCMFileAudioSource(playlist: clips, speed: options.speed)

var sessionConfiguration = TranslationSession.Configuration()
sessionConfiguration.idleTimeout = nil
let session = TranslationSession(
    audio: audio,
    connector: WebSocketSTTConnector(),
    credentials: client,
    translator: translator,
    connectivity: AlwaysOnline(),
    speech: (synthesizer, audio),
    configuration: sessionConfiguration
)
await session.setSpeaksTranslations(options.speak)

func residentMegabytes() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}


let collector = Collector()
let startedAt = Date()
let memoryAtStart = residentMegabytes()
var memorySamples: [(Double, Double)] = [(0, memoryAtStart)]

print("Playing \(clips.count) clips (\(String(format: "%.0f", clips.reduce(0) { $0 + Double($1.pcm.count) } / 32_000))s of speech) at \(options.speed)x against \(options.baseURL.absoluteString)\n")

let consumer = Task {
    for await event in session.events {
        switch event {
        case .status(let status):
            collector.statuses.append((Date(), status))
            if status != .listening { print("  · status: \(status)") }
        case .notice(let notice):
            collector.notices.append(notice)
            print("  ! notice: \(notice)")
        case .phrase(let phrase):
            collector.check(phrase)
            collector.phrases[phrase.id] = phrase
            if phrase.isSettled, collector.printed.insert(phrase.id).inserted {
                let latency = phrase.timing.translationLatency.map { String(format: "%4.0f ms", $0 * 1000) } ?? "      –"
                let english: String
                switch phrase.translation {
                case .completed(let text): english = text
                case .unavailable(let reason): english = "(\(reason))"
                default: english = ""
                }
                print("\(phrase.id) [\(phrase.languageCode ?? "??")] \(latency)  \(phrase.sourceText)\n         → \(english)")
            }
        case .removed(let id):
            collector.phrases[id] = nil
        case .speaking(let id):
            collector.speaking = id
            if let id {
                collector.spoken.append(id)
                collector.speechStarts.append((id, Date()))
                print("  🔈 speaking \(id)")
            }
        case .level, .speechQueueDepth:
            break
        }
    }
}

let dropper = Task {
    guard let interval = options.dropEvery else { return }
    var request = URLRequest(url: options.baseURL.appendingPathComponent("__mock/drop"))
    request.httpMethod = "POST"
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        if Task.isCancelled { return }
        _ = try? await URLSession.shared.data(for: request)
        print("  ✂ dropped the STT connection")
    }
}

await session.start()
while !audio.isFinished {
    try? await Task.sleep(for: .seconds(1))
    let elapsed = Date().timeIntervalSince(startedAt)
    if memorySamples.last.map({ elapsed - $0.0 >= 30 }) ?? true {
        memorySamples.append((elapsed, residentMegabytes()))
    }
    if collector.statuses.last?.1 == .idle { break }
}
// Let the last turn finalize and translate, as a user would before tapping Stop.
try? await Task.sleep(for: .seconds(3))
if options.speak {
    // And let the phone finish talking, within reason.
    let deadline = Date().addingTimeInterval(30)
    while collector.speaking != nil, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(200))
    }
}
dropper.cancel()
await session.stop()
try? await Task.sleep(for: .milliseconds(300))
consumer.cancel()
memorySamples.append((Date().timeIntervalSince(startedAt), residentMegabytes()))

// MARK: - Report

let playback = audio.playback
let phrases = collector.phrases.values.sorted { $0.id < $1.id }

// A phrase belongs to the clip that was playing when it was first heard.
var phrasesByClip = Array(repeating: [Phrase](), count: playback.count)
for phrase in phrases {
    let index = playback.lastIndex { $0.startedAt <= phrase.timing.startedAt } ?? 0
    if !playback.isEmpty { phrasesByClip[index].append(phrase) }
}

var results: [ClipResult] = []
for (index, clip) in playback.enumerated() {
    guard let sample = samplesByID[clip.id] else { continue }
    let own = phrasesByClip[index]
    let recognized = own.map(\.sourceText).joined(separator: " ")
    let reference = normalized(sample.text)
    let errorRate = reference.isEmpty ? 0 : Double(editDistance(reference, normalized(recognized))) / Double(reference.count)
    var captionLatency: Double?
    if let ended = clip.endedAt, let completed = own.compactMap(\.timing.translationCompletedAt).max() {
        captionLatency = completed.timeIntervalSince(ended)
    }
    results.append(ClipResult(
        id: clip.id,
        expectedLanguage: sample.language,
        detectedLanguages: own.compactMap(\.languageCode),
        reference: sample.text,
        recognized: recognized,
        characterErrorRate: errorRate,
        referenceEnglish: sample.english,
        english: own.compactMap(\.english).joined(separator: " "),
        phrases: own.count,
        speechEndToCaptionSeconds: captionLatency
    ))
}

let translated = phrases.filter { $0.english != nil }
let firstText = translated.compactMap(\.timing.firstTextLatency)
let fullTranslation = translated.compactMap(\.timing.translationLatency)
let speechToCaption = results.compactMap(\.speechEndToCaptionSeconds)
let unavailable = phrases.filter { if case .unavailable = $0.translation { true } else { false } }
let reconnects = collector.statuses.filter { $0.1 == .reconnecting }.count
let unsettled = phrases.filter { !$0.isSettled }.count
let spokenOutOfOrder = zip(collector.spoken, collector.spoken.dropFirst()).filter { $0 >= $1 }.count
let integrityProblems = collector.outOfOrder + collector.changedAfterSettling + collector.reopened + unsettled + spokenOutOfOrder
let usage = translator.usage
let audioSeconds = audio.audioSeconds
let sttCost = audioSeconds / 3600 * options.sttPricePerHour
let llmCost = Double(usage.prompt) / 1e6 * options.inputPricePerMillion + Double(usage.completion) / 1e6 * options.outputPricePerMillion
let speech = synthesizer.usage
let ttsCost = Double(speech.characters) / 1e6 * options.ttsPricePerMillion
let elapsed = Date().timeIntervalSince(startedAt)

print("\n=== Per clip ===")
print("id                       lang  detected   CER    speech→caption")
for result in results {
    let detected = result.detectedLanguages.isEmpty ? "–" : Array(Set(result.detectedLanguages)).sorted().joined(separator: ",")
    let flag = result.detectedLanguages.contains(result.expectedLanguage) ? " " : "✗"
    print(pad(result.id, 24) + " " + pad(result.expectedLanguage, 5) + " " + flag + pad(detected, 9) + String(format: " %5.1f%%  ", result.characterErrorRate * 100) + ms(result.speechEndToCaptionSeconds))
}

print("\n=== Summary ===")
print("Clips: \(results.count), phrases: \(phrases.count), translated: \(translated.count), without translation: \(unavailable.count)")
print("Language detected as expected: \(results.filter { $0.detectedLanguages.contains($0.expectedLanguage) }.count)/\(results.count)")
let cers = results.map(\.characterErrorRate)
print(String(format: "Recognition CER: median %.1f%%, mean %.1f%%", (percentile(cers, 0.5) ?? 0) * 100, cers.reduce(0, +) / Double(max(1, cers.count)) * 100))
print("Final transcript → first English text: p50 \(ms(percentile(firstText, 0.5))), p95 \(ms(percentile(firstText, 0.95)))")
print("Final transcript → complete English:   p50 \(ms(percentile(fullTranslation, 0.5))), p95 \(ms(percentile(fullTranslation, 0.95)))")
print("End of speech → complete English:      p50 \(ms(percentile(speechToCaption, 0.5))), p95 \(ms(percentile(speechToCaption, 0.95)))")
print("Reconnects: \(reconnects), notices: \(collector.notices.isEmpty ? "none" : collector.notices.map { "\($0)" }.joined(separator: ", "))")
print("Integrity: \(integrityProblems == 0 ? "ok" : "PROBLEMS") — new phrases out of order \(collector.outOfOrder), changed after settling \(collector.changedAfterSettling), final reopened \(collector.reopened), unsettled after Stop \(unsettled)\(options.speak ? ", spoken out of order \(spokenOutOfOrder)" : "")")
let speechStartDelays = collector.speechStarts.compactMap { (id, at) in
    collector.phrases[id]?.timing.translationCompletedAt.map { at.timeIntervalSince($0) }
}
let speechGaps = zip(collector.speechStarts, collector.speechStarts.dropFirst()).map { $1.1.timeIntervalSince($0.1) }
if options.speak {
    print("Speech: \(collector.spoken.count) phrases spoken, \(speech.requests) requests (\(speech.failures) failed), \(speech.characters) characters, " + String(format: "%.0fs of audio", audio.speechSeconds))
    print("Speech request → first audio: p50 \(ms(percentile(speech.firstAudio, 0.5))), p95 \(ms(percentile(speech.firstAudio, 0.95)))")
    print("Speech speed: \(options.speakingRate)×")
    print("Translation complete → speech start: p50 \(ms(percentile(speechStartDelays, 0.5))), p95 \(ms(percentile(speechStartDelays, 0.95)))")
    print("Time between spoken phrases: p50 \(ms(percentile(speechGaps, 0.5))), p95 \(ms(percentile(speechGaps, 0.95)))")
}
print(String(format: "Audio streamed: %.0fs; session wall time: %.0fs", audioSeconds, elapsed))
print("Translation requests: \(usage.requests), tokens in/out: \(usage.prompt)/\(usage.completion), models: \(usage.models.map { "\($0.key) ×\($0.value)" }.sorted().joined(separator: ", "))")
let totalCost = sttCost + llmCost + ttsCost
print(String(format: "Estimated cost: STT $%.4f + LLM $%.4f\(options.speak ? String(format: " + TTS $%.4f", ttsCost) : "") = $%.4f (≈ $%.3f per hour of streaming)", sttCost, llmCost, totalCost, audioSeconds > 0 ? totalCost / audioSeconds * 3600 : 0))
print("Memory (MB resident): " + memorySamples.map { String(format: "%.0fs %.1f", $0.0, $0.1) }.joined(separator: " · "))

if let reportURL = options.report {

    let report = CliReportPayload(
        baseURL: options.baseURL.absoluteString, speed: options.speed, clips: results,
        firstTextLatencyP50: percentile(firstText, 0.5),
        translationLatencyP50: percentile(fullTranslation, 0.5), translationLatencyP95: percentile(fullTranslation, 0.95),
        speechToCaptionP50: percentile(speechToCaption, 0.5), speechToCaptionP95: percentile(speechToCaption, 0.95),
        reconnects: reconnects, integrityProblems: integrityProblems,
        phrasesSpoken: collector.spoken.count, speechCharacters: speech.characters,
        speakingRate: options.speakingRate,
        speechFirstAudioP50: percentile(speech.firstAudio, 0.5), speechFirstAudioP95: percentile(speech.firstAudio, 0.95),
        speechStartDelayP50: percentile(speechStartDelays, 0.5), speechStartDelayP95: percentile(speechStartDelays, 0.95),
        speechGapP50: percentile(speechGaps, 0.5), speechGapP95: percentile(speechGaps, 0.95),
        audioSeconds: audioSeconds,
        promptTokens: usage.prompt, completionTokens: usage.completion,
        estimatedCostUSD: totalCost, memoryMegabytes: memorySamples.map(\.1)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(report).write(to: reportURL)
    print("Report written to \(reportURL.path)")
}

// Fail the run for scripts when phrases arrived out of order or unsettled.
if integrityProblems > 0 { exit(1) }
