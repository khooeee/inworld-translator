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

    private struct FileVersion: Decodable {
        let version: Int
    }

    private struct LegacyFileContents: Decodable {
        struct LegacyCaption: Decodable {
            enum Translation: Decodable {
                case completed(english: String)
                case unavailable(reason: TranslationUnavailableReason)
            }

            let sourceText: String
            let wasInterrupted: Bool
            let translation: Translation
            let languageCode: String?
            let timing: PhraseTiming

            var upgraded: Caption {
                let saved: Caption.Translation = switch translation {
                case .completed(let english): .completed(text: english)
                case .unavailable(let reason): .unavailable(reason: reason)
                }
                return Caption(
                    sourceText: sourceText,
                    wasInterrupted: wasInterrupted,
                    translation: saved,
                    languageCode: languageCode,
                    targetLanguage: .english,
                    timing: timing
                )
            }
        }

        let captions: [LegacyCaption]
    }

    private struct Caption: Codable {
        enum Translation: Codable {
            case completed(text: String)
            case unavailable(reason: TranslationUnavailableReason)
        }

        let sourceText: String
        let wasInterrupted: Bool
        let translation: Translation
        let languageCode: String?
        let targetLanguage: TargetLanguage
        let timing: PhraseTiming

        static func archive(_ phrase: Phrase) -> Self? {
            guard phrase.sourceState != .provisional else { return nil }
            let saved: Translation = switch phrase.translation {
            case .completed(let text): .completed(text: text)
            case .unavailable(let reason): .unavailable(reason: reason)
            case .none, .pending, .partial: .unavailable(reason: .cancelled)
            }
            return Caption(
                sourceText: phrase.sourceText,
                wasInterrupted: phrase.sourceState == .interrupted,
                translation: saved,
                languageCode: phrase.languageCode,
                targetLanguage: phrase.targetLanguage,
                timing: phrase.timing
            )
        }

        func phrase(id: PhraseID) -> Phrase {
            let restored: Phrase.Translation = switch translation {
            case .completed(let text): .completed(text)
            case .unavailable(let reason): .unavailable(reason)
            }
            return Phrase(
                id: id,
                sourceText: sourceText,
                sourceState: wasInterrupted ? .interrupted : .final,
                translation: restored,
                languageCode: languageCode,
                targetLanguage: targetLanguage,
                timing: timing
            )
        }
    }

    private static let version = 2
    private let captions: [Caption]

    var isEmpty: Bool { captions.isEmpty }

    init(phrases: [Phrase]) {
        captions = phrases.compactMap(Caption.archive)
    }

    init(data: Data, maxPhrases: Int) throws {
        let decoder = JSONDecoder()
        let version = try decoder.decode(FileVersion.self, from: data).version
        let loaded: [Caption]
        switch version {
        case 1:
            loaded = try decoder.decode(LegacyFileContents.self, from: data).captions.map(\.upgraded)
        case Self.version:
            loaded = try decoder.decode(FileContents.self, from: data).captions
        default:
            throw FileError.unsupportedVersion
        }
        guard !loaded.isEmpty, loaded.count <= maxPhrases else { throw FileError.invalidCaptionCount }
        captions = loaded
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
