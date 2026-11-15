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
//   --report PATH       also write the report as JSON
//   --stt-price X       USD per hour of audio (default 0.15, On-Demand)
//   --input-price X     USD per million input tokens (default 0.10)
//   --output-price X    USD per million output tokens (default 0.40)

import Darwin
import Foundation
import TranslatorCore

struct Options {
    var manifest: URL
    var baseURL = URL(string: "https://api.inworld.ai")!
    var speed = 1.0
    var loops = 1
    var only: Set<String>?
    var dropEvery: Double?
    var model: String?
    var report: URL?
    var sttPricePerHour = 0.15
    var inputPricePerMillion = 0.10
    var outputPricePerMillion = 0.40

    static func parse(_ arguments: [String]) -> Options {
        var manifest: URL?
        var options = Options(manifest: URL(fileURLWithPath: "/"))
        var iterator = arguments.dropFirst().makeIterator()
        func value(_ flag: String) -> String {
            guard let value = iterator.next() else { fail("\(flag) needs a value") }
            return value
        }
        func number(_ flag: String) -> Double {
            guard let number = Double(value(flag)) else { fail("\(flag) needs a number") }
            return number
        }
        while let argument = iterator.next() {
            switch argument {
            case "--base-url": options.baseURL = URL(string: value(argument)) ?? { fail("bad --base-url") }()
            case "--speed": options.speed = number(argument)
            case "--loops": options.loops = Int(number(argument))
            case "--only": options.only = Set(value(argument).split(separator: ",").map(String.init))
            case "--drop-every": options.dropEvery = number(argument)
            case "--model": options.model = value(argument)
            case "--report": options.report = URL(fileURLWithPath: value(argument))
            case "--stt-price": options.sttPricePerHour = number(argument)
            case "--input-price": options.inputPricePerMillion = number(argument)
            case "--output-price": options.outputPricePerMillion = number(argument)
            case "-h", "--help":
                print("usage: translator-cli MANIFEST [--base-url URL] [--speed X] [--loops N] [--only ids] [--drop-every S] [--model ID] [--report PATH]")
                exit(0)
            default:
                if argument.hasPrefix("-") { fail("unknown option \(argument)") }
                manifest = URL(fileURLWithPath: argument)
            }
        }
        guard let manifest else { fail("give the path to a samples manifest") }
        options.manifest = manifest
        return options
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

struct Manifest: Decodable {
    struct Sample: Decodable {
        let id: String
        let language: String
        let text: String
        let english: String
    }

    let samples: [Sample]
}

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
let client = InworldClient(configuration: clientConfiguration) { apiKey }
let translator = MeteredTranslator(client)
let audio = PCMFileAudioSource(playlist: clips, speed: options.speed)

var sessionConfiguration = TranslationSession.Configuration()
sessionConfiguration.idleTimeout = nil
let session = TranslationSession(
    audio: audio,
    connector: WebSocketSTTConnector(),
    credentials: client,
    translator: translator,
    connectivity: AlwaysOnline(),
    configuration: sessionConfiguration
)

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

final class Collector: @unchecked Sendable {
    // Touched only from the single consumer task below.
    var phrases: [PhraseID: Phrase] = [:]
    var statuses: [(Date, SessionStatus)] = []
    var notices: [SessionNotice] = []
    var printed: Set<PhraseID> = []
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
        case .level:
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
dropper.cancel()
await session.stop()
try? await Task.sleep(for: .milliseconds(300))
consumer.cancel()
memorySamples.append((Date().timeIntervalSince(startedAt), residentMegabytes()))

// MARK: - Report

/// Characters that carry meaning, lowercased, so punctuation, spacing and
/// case do not count as recognition errors.
func normalized(_ text: String) -> [Character] {
    Array(text.lowercased().unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) }
        .map(Character.init))
}

func editDistance(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    for (i, x) in a.enumerated() {
        var current = [i + 1] + Array(repeating: 0, count: b.count)
        for (j, y) in b.enumerated() {
            current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
        }
        previous = current
    }
    return previous[b.count]
}

func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func ms(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0 * 1000) } ?? "–"
}

struct ClipResult: Encodable {
    let id: String
    let expectedLanguage: String
    let detectedLanguages: [String]
    let reference: String
    let recognized: String
    let characterErrorRate: Double
    let referenceEnglish: String
    let english: String
    let phrases: Int
    let speechEndToCaptionSeconds: Double?
}

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
let usage = translator.usage
let audioSeconds = audio.audioSeconds
let sttCost = audioSeconds / 3600 * options.sttPricePerHour
let llmCost = Double(usage.prompt) / 1e6 * options.inputPricePerMillion + Double(usage.completion) / 1e6 * options.outputPricePerMillion
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
print(String(format: "Audio streamed: %.0fs; session wall time: %.0fs", audioSeconds, elapsed))
print("Translation requests: \(usage.requests), tokens in/out: \(usage.prompt)/\(usage.completion), models: \(usage.models.map { "\($0.key) ×\($0.value)" }.sorted().joined(separator: ", "))")
print(String(format: "Estimated cost: STT $%.4f + LLM $%.4f = $%.4f (≈ $%.3f per hour of streaming)", sttCost, llmCost, sttCost + llmCost, audioSeconds > 0 ? (sttCost + llmCost) / audioSeconds * 3600 : 0))
print("Memory (MB resident): " + memorySamples.map { String(format: "%.0fs %.1f", $0.0, $0.1) }.joined(separator: " · "))

if let reportURL = options.report {
    struct Report: Encodable {
        let baseURL: String
        let speed: Double
        let clips: [ClipResult]
        let firstTextLatencyP50: Double?
        let translationLatencyP50: Double?
        let translationLatencyP95: Double?
        let speechToCaptionP50: Double?
        let speechToCaptionP95: Double?
        let reconnects: Int
        let audioSeconds: Double
        let promptTokens: Int
        let completionTokens: Int
        let estimatedCostUSD: Double
        let memoryMegabytes: [Double]
    }
    let report = Report(
        baseURL: options.baseURL.absoluteString, speed: options.speed, clips: results,
        firstTextLatencyP50: percentile(firstText, 0.5),
        translationLatencyP50: percentile(fullTranslation, 0.5), translationLatencyP95: percentile(fullTranslation, 0.95),
        speechToCaptionP50: percentile(speechToCaption, 0.5), speechToCaptionP95: percentile(speechToCaption, 0.95),
        reconnects: reconnects, audioSeconds: audioSeconds,
        promptTokens: usage.prompt, completionTokens: usage.completion,
        estimatedCostUSD: sttCost + llmCost, memoryMegabytes: memorySamples.map(\.1)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(report).write(to: reportURL)
    print("Report written to \(reportURL.path)")
}
