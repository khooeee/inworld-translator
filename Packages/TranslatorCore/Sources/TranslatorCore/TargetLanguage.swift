import Foundation

/// The app's language catalog, shared by the speech recognition list and
/// the translation target picker.
public enum TargetLanguage: String, CaseIterable, Codable, Sendable {
    case arabic = "ar"
    case cantonese = "yue"
    case chinese = "zh"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case english = "en"
    case filipino = "fil"
    case finnish = "fi"
    case french = "fr"
    case german = "de"
    case greek = "el"
    case hindi = "hi"
    case hungarian = "hu"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case macedonian = "mk"
    case malay = "ms"
    case persian = "fa"
    case polish = "pl"
    case portuguese = "pt"
    case romanian = "ro"
    case russian = "ru"
    case spanish = "es"
    case swedish = "sv"
    case thai = "th"
    case turkish = "tr"
    case vietnamese = "vi"

    public func name(in locale: Locale = .current) -> String {
        locale.localizedString(forLanguageCode: rawValue) ?? rawValue
    }

    func matches(_ sourceCode: String?) -> Bool {
        guard let sourceCode else { return false }
        let base = sourceCode.lowercased().prefix { $0 != "-" && $0 != "_" }
        switch base {
        case "cmn": return self == .chinese
        case "tl": return self == .filipino
        default: return base == rawValue
        }
    }
}
