import TranslatorCore
import UIKit

/// One phrase with language labels, the original words, and their translation.
final class PhraseCell: UITableViewCell {
    static let reuseIdentifier = "PhraseCell"

    private let headerLabel = UILabel()
    private let sourceLabel = UILabel()
    private let translationLabel = UILabel()

    /// Copy actions for VoiceOver, which has no long-press menu.
    var onCopy: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        for label in [headerLabel, sourceLabel, translationLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .natural
        }
        headerLabel.font = .preferredFont(forTextStyle: .caption1)
        headerLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [headerLabel, sourceLabel, translationLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(6, after: sourceLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])

        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with phrase: Phrase, isSpeaking: Bool = false) {
        let spokenInTargetLanguage = phrase.isSpokenInTargetLanguage
        let targetName = phrase.targetLanguage.name()

        var header: [String] = []
        if phrase.sourceState == .provisional {
            header.append(String(localized: "Listening…"))
        } else if let sourceName = Self.languageName(phrase.languageCode) {
            header.append(spokenInTargetLanguage ? sourceName : String(localized: "\(sourceName) → \(targetName)"))
        } else {
            header.append(String(localized: "To \(targetName)"))
        }
        if phrase.sourceState == .interrupted {
            header.append(String(localized: "cut off"))
        }
        if isSpeaking {
            header.append(String(localized: "Speaking"))
        }
        headerLabel.text = header.joined(separator: " · ")
        headerLabel.isHidden = header.isEmpty

        // The source appears at full strength when it is the caption itself.
        sourceLabel.text = phrase.sourceText
        switch phrase.sourceState {
        case .provisional:
            sourceLabel.font = Self.font(.body, italic: true)
            sourceLabel.textColor = .tertiaryLabel
        case .final, .interrupted:
            sourceLabel.font = Self.font(spokenInTargetLanguage ? .title3 : .body, weight: spokenInTargetLanguage ? .semibold : .regular)
            sourceLabel.textColor = spokenInTargetLanguage ? .label : .secondaryLabel
        }

        // Translation.
        translationLabel.font = Self.font(.title3, weight: .semibold)
        translationLabel.isHidden = spokenInTargetLanguage
        switch phrase.translation {
        case .none:
            translationLabel.isHidden = true
        case .pending:
            translationLabel.text = String(localized: "Translating…")
            translationLabel.font = Self.font(.body, italic: true)
            translationLabel.textColor = .tertiaryLabel
        case .partial(let text):
            translationLabel.text = text
            translationLabel.textColor = .secondaryLabel
        case .completed(let text):
            translationLabel.text = text
            translationLabel.textColor = .label
        case .unavailable(let reason):
            translationLabel.text = Self.describe(reason)
            translationLabel.font = Self.font(.subheadline, italic: true)
            translationLabel.textColor = .secondaryLabel
        }

        updateAccessibility(for: phrase)
    }

    private func updateAccessibility(for phrase: Phrase) {
        let label = NSMutableAttributedString()
        func append(_ text: String, language: String? = nil) {
            if label.length > 0 {
                label.append(NSAttributedString(string: ". "))
            }
            let attributes: [NSAttributedString.Key: Any] = language.map { [.accessibilitySpeechLanguage: $0] } ?? [:]
            label.append(NSAttributedString(string: text, attributes: attributes))
        }
        if let language = Self.languageName(phrase.languageCode), !phrase.isSpokenInTargetLanguage {
            append(language)
        }
        append(phrase.sourceText, language: phrase.languageCode == "und" ? nil : phrase.languageCode)
        if !translationLabel.isHidden, let translation = translationLabel.text {
            switch phrase.translation {
            case .partial, .completed:
                append(phrase.targetLanguage.name())
                append(translation, language: phrase.targetLanguage.rawValue)
            default:
                append(translation)
            }
        }
        accessibilityAttributedLabel = label

        switch (phrase.sourceState, phrase.translation) {
        case (.provisional, _): accessibilityValue = String(localized: "Still listening")
        case (_, .pending), (_, .partial):
            accessibilityValue = phrase.isSpokenInTargetLanguage ? nil : String(localized: "Translating")
        default: accessibilityValue = nil
        }

        var actions: [UIAccessibilityCustomAction] = []
        if let translation = phrase.translatedText, !phrase.isSpokenInTargetLanguage {
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Copy Translation")) { [weak self] _ in
                self?.onCopy?(translation)
                return true
            })
        }
        let source = phrase.sourceText
        actions.append(UIAccessibilityCustomAction(name: String(localized: "Copy original")) { [weak self] _ in
            self?.onCopy?(source)
            return true
        })
        accessibilityCustomActions = actions
    }

    static func languageName(_ code: String?) -> String? {
        guard let code, code != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    static func describe(_ reason: TranslationUnavailableReason) -> String {
        switch reason {
        case .failed: String(localized: "Couldn't translate this phrase.")
        case .skipped: String(localized: "Skipped to keep up with the conversation.")
        case .cancelled: String(localized: "Stopped before it was translated.")
        case .unintelligible: String(localized: "No words to translate.")
        case .limitReached: String(localized: "Not translated: Inworld usage limit.")
        }
    }

    private static func font(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        // Start from the default-size font: UIFontMetrics applies the user's
        // text size, and starting from an already scaled font would scale twice.
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        var descriptor = base.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
            descriptor = slanted
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: base.pointSize))
    }
}
