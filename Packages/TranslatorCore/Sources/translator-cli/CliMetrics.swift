import Foundation
import TranslatorCore

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

struct CliReportPayload: Encodable {
    let baseURL: String
    let speed: Double
    let clips: [ClipResult]
    let firstTextLatencyP50: Double?
    let translationLatencyP50: Double?
    let translationLatencyP95: Double?
    let speechToCaptionP50: Double?
    let speechToCaptionP95: Double?
    let reconnects: Int
    let integrityProblems: Int
    let phrasesSpoken: Int
    let speechCharacters: Int
    let speakingRate: Double
    let speechFirstAudioP50: Double?
    let speechFirstAudioP95: Double?
    let speechStartDelayP50: Double?
    let speechStartDelayP95: Double?
    let speechGapP50: Double?
    let speechGapP95: Double?
    let audioSeconds: Double
    let promptTokens: Int
    let completionTokens: Int
    let estimatedCostUSD: Double
    let memoryMegabytes: [Double]
}
