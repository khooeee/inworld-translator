import TranslatorCore
import UIKit

/// One phrase with language labels, the original words, and their translation.
final class PhraseCell: UITableViewCell {
    static let reuseIdentifier = "PhraseCell"

    private let headerLabel = UILabel()
    private let sourceLabel = UILabel()
    private let translationLabel = UILabel()
    private let sourceBubble = SpeechBubbleView(tail: .leading, fill: TranslationTheme.original)
    private let translationBubble = SpeechBubbleView(tail: .trailing, fill: TranslationTheme.translated)
    private let translationRow = UIStackView()

    /// Copy actions for VoiceOver, which has no long-press menu.
    var onCopy: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        for label in [headerLabel, sourceLabel, translationLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .natural
        }
        headerLabel.font = Self.font(.caption1, weight: .semibold)
        headerLabel.textColor = TranslationTheme.secondaryText

        let sourceRow = UIStackView()
        configureBubble(sourceBubble, label: sourceLabel, row: sourceRow, leading: 0, trailing: 26)
        configureBubble(translationBubble, label: translationLabel, row: translationRow, leading: 26, trailing: 0)

        let stack = UIStackView(arrangedSubviews: [headerLabel, sourceRow, translationRow])
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])

        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureBubble(
        _ bubble: SpeechBubbleView, label: UILabel, row: UIStackView, leading: CGFloat, trailing: CGFloat
    ) {
        row.axis = .vertical
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing)
        row.addArrangedSubview(bubble)
        bubble.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 11, leading: 20, bottom: 17, trailing: 20)
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)
        let margins = bubble.layoutMarginsGuide
        let bottom = label.bottomAnchor.constraint(equalTo: margins.bottomAnchor)
        // A hidden arranged row collapses to zero height.
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            label.topAnchor.constraint(equalTo: margins.topAnchor),
            bottom,
        ])
    }

    func configure(with phrase: Phrase, isSpeaking: Bool = false) {
        let spokenInTargetLanguage = phrase.isSpokenInTargetLanguage
        let targetName = phrase.targetLanguage.name()
        let outsideLanguagePair = phrase.translation == .unavailable(.outsideLanguagePair)
        let showsOnlySource = spokenInTargetLanguage || outsideLanguagePair

        var header: [String] = []
        if phrase.sourceState == .provisional {
            header.append(String(localized: "Listening…"))
        } else if let sourceName = Self.languageName(phrase.languageCode) {
            header.append(showsOnlySource ? sourceName : String(localized: "\(sourceName) → \(targetName)"))
        } else if phrase.translation != .pending, !outsideLanguagePair {
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
        headerLabel.textColor = isSpeaking ? TranslationTheme.accent : TranslationTheme.secondaryText
        translationBubble.strokeColor = isSpeaking ? TranslationTheme.accent : TranslationTheme.outline

        // The source appears at full strength when it is the caption itself.
        sourceLabel.text = phrase.sourceText
        switch phrase.sourceState {
        case .provisional:
            sourceLabel.font = Self.font(.body, italic: true)
            sourceLabel.textColor = TranslationTheme.secondaryText
        case .final, .interrupted:
            sourceLabel.font = Self.font(showsOnlySource ? .title3 : .body, weight: showsOnlySource ? .semibold : .regular)
            sourceLabel.textColor = showsOnlySource ? .label : TranslationTheme.secondaryText
        }

        // Translation.
        translationLabel.font = Self.font(.title3, weight: .semibold)
        translationRow.isHidden = showsOnlySource
        switch phrase.translation {
        case .none:
            translationRow.isHidden = true
        case .pending:
            translationLabel.text = String(localized: "Translating…")
            translationLabel.font = Self.font(.body, italic: true)
            translationLabel.textColor = TranslationTheme.secondaryText
        case .partial(let text):
            translationLabel.text = text
            translationLabel.textColor = TranslationTheme.secondaryText
        case .completed(let text):
            translationLabel.text = text
            translationLabel.textColor = TranslationTheme.accent
        case .unavailable(let reason):
            translationLabel.text = Self.describe(reason)
            translationLabel.font = Self.font(.subheadline, italic: true)
            translationLabel.textColor = TranslationTheme.secondaryText
        }

        updateAccessibility(for: phrase, isSpeaking: isSpeaking)
    }

    private func updateAccessibility(for phrase: Phrase, isSpeaking: Bool) {
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
        if !translationRow.isHidden, let translation = translationLabel.text {
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
        case _ where isSpeaking: accessibilityValue = String(localized: "Speaking")
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
        case .outsideLanguagePair: String(localized: "Neither selected language was recognized.")
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
        let font = UIFont(descriptor: descriptor, size: base.pointSize)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: weight == .semibold ? TranslationTheme.rounded(font) : font)
    }
}
