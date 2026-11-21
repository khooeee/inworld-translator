import Foundation
import TranslatorCore

struct ConversationArchive: Sendable {
    enum FileError: Error {
        case unsupportedVersion
        case invalidCaptionCount
    }

    private struct FileContents: Codable {
        let version: Int
        let captions: [Caption]
    }

    private struct Caption: Codable {
        enum Translation: Codable {
            case completed(english: String)
            case unavailable(reason: TranslationUnavailableReason)
        }

        let sourceText: String
        let wasInterrupted: Bool
        let translation: Translation
        let languageCode: String?
        let timing: PhraseTiming

        init?(_ phrase: Phrase) {
            guard phrase.sourceState != .provisional else { return nil }
            sourceText = phrase.sourceText
            wasInterrupted = phrase.sourceState == .interrupted
            languageCode = phrase.languageCode
            timing = phrase.timing
            switch phrase.translation {
            case .completed(let english): translation = .completed(english: english)
            case .unavailable(let reason): translation = .unavailable(reason: reason)
            case .none, .pending, .partial: translation = .unavailable(reason: .cancelled)
            }
        }

        func phrase(id: PhraseID) -> Phrase {
            let restored: Phrase.Translation = switch translation {
            case .completed(let english): .completed(english)
            case .unavailable(let reason): .unavailable(reason)
            }
            return Phrase(
                id: id,
                sourceText: sourceText,
                sourceState: wasInterrupted ? .interrupted : .final,
                translation: restored,
                languageCode: languageCode,
                timing: timing
            )
        }
    }

    private static let version = 1
    private let captions: [Caption]

    var isEmpty: Bool { captions.isEmpty }

    init(phrases: [Phrase]) {
        captions = phrases.compactMap(Caption.init)
    }

    init(data: Data, maxPhrases: Int) throws {
        let contents = try JSONDecoder().decode(FileContents.self, from: data)
        guard contents.version == Self.version else { throw FileError.unsupportedVersion }
        guard !contents.captions.isEmpty, contents.captions.count <= maxPhrases else { throw FileError.invalidCaptionCount }
        captions = contents.captions
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(FileContents(version: Self.version, captions: captions))
    }

    func writeForExport() throws -> URL {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let timestamp = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let file = directory.appendingPathComponent("Conversation-\(timestamp).json")
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try encoded().write(to: file, options: .atomic)
            return file
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    func restoredPhrases() -> [Phrase] {
        // Live phrases use positive IDs. Keep imported captions ahead of them
        // and preserve the order in the file.
        captions.enumerated().map { index, caption in
            caption.phrase(id: PhraseID(index - captions.count))
        }
    }
}
