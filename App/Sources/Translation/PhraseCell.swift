import TranslatorCore
import UIKit

/// One phrase: a small header with the language, the original words, and the
/// English translation beneath them.
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
        let spokenInEnglish = phrase.isSpokenInEnglish

        // Header: language, and whether the phrase is still being heard or
        // is being read aloud.
        var header: [String] = []
        if phrase.sourceState == .provisional {
            header.append(String(localized: "Listening…"))
        } else if let language = Self.languageName(phrase.languageCode) {
            header.append(language)
        }
        if phrase.sourceState == .interrupted {
            header.append(String(localized: "cut off"))
        }
        if isSpeaking {
            header.append(String(localized: "Speaking"))
        }
        headerLabel.text = header.joined(separator: " · ")
        headerLabel.isHidden = header.isEmpty

        // Source: italic and faint while the recognizer may still revise it.
        // English speech is shown as the caption itself, at full strength.
        sourceLabel.text = phrase.sourceText
        switch phrase.sourceState {
        case .provisional:
            sourceLabel.font = Self.font(.body, italic: true)
            sourceLabel.textColor = .tertiaryLabel
        case .final, .interrupted:
            sourceLabel.font = Self.font(spokenInEnglish ? .title3 : .body, weight: spokenInEnglish ? .semibold : .regular)
            sourceLabel.textColor = spokenInEnglish ? .label : .secondaryLabel
        }

        // Translation.
        translationLabel.font = Self.font(.title3, weight: .semibold)
        switch phrase.translation {
        case .none:
            translationLabel.isHidden = true
        case .pending:
            translationLabel.isHidden = spokenInEnglish
            translationLabel.text = String(localized: "Translating…")
            translationLabel.font = Self.font(.body, italic: true)
            translationLabel.textColor = .tertiaryLabel
        case .partial(let text):
            translationLabel.isHidden = spokenInEnglish
            translationLabel.text = text
            translationLabel.textColor = .secondaryLabel
        case .completed(let text):
            translationLabel.isHidden = spokenInEnglish
            translationLabel.text = text
            translationLabel.textColor = .label
        case .unavailable(let reason):
            translationLabel.isHidden = false
            translationLabel.text = Self.describe(reason)
            translationLabel.font = Self.font(.subheadline, italic: true)
            translationLabel.textColor = .secondaryLabel
        }

        updateAccessibility(for: phrase)
    }

    private func updateAccessibility(for phrase: Phrase) {
        let language = Self.languageName(phrase.languageCode)
        var parts: [String] = []
        if let language, !phrase.isSpokenInEnglish {
            parts.append(String(localized: "\(language): \(phrase.sourceText)"))
        } else {
            parts.append(phrase.sourceText)
        }
        if !translationLabel.isHidden, let translation = translationLabel.text {
            switch phrase.translation {
            case .partial, .completed:
                parts.append(String(localized: "English: \(translation)"))
            default:
                parts.append(translation)
            }
        }
        accessibilityLabel = parts.joined(separator: ". ")

        switch (phrase.sourceState, phrase.translation) {
        case (.provisional, _): accessibilityValue = String(localized: "Still listening")
        case (_, .pending), (_, .partial): accessibilityValue = String(localized: "Translating")
        default: accessibilityValue = nil
        }

        var actions: [UIAccessibilityCustomAction] = []
        if let english = phrase.english, !phrase.isSpokenInEnglish {
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Copy English")) { [weak self] _ in
                self?.onCopy?(english)
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
