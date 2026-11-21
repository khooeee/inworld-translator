import TranslatorCore
import UIKit

final class LanguagePickerViewController: UITableViewController {
    enum Mode {
        case source
        case target

        var title: String {
            switch self {
            case .source: String(localized: "From")
            case .target: String(localized: "To")
            }
        }
    }

    static let autoDetectTitle = String(localized: "Auto Detect")

    private struct Option {
        /// Nil represents automatic source language detection.
        let language: TranslationLanguage?
        /// In the reader's language, e.g. "Japanese".
        let name: String
        /// In the language itself, e.g. "日本語".
        let nativeName: String?
    }

    private let mode: Mode
    private let options: [Option]
    private let current: TranslationLanguage?
    private let onSelect: (TranslationLanguage?) -> Void

    init(mode: Mode, current: TranslationLanguage?, onSelect: @escaping (TranslationLanguage?) -> Void) {
        self.mode = mode
        self.current = current
        self.onSelect = onSelect
        let languages = TranslationLanguage.allCases
            .map { language in
                Option(
                    language: language,
                    name: language.name(),
                    nativeName: language.name(in: Locale(identifier: language.rawValue))
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        options = mode == .source
            ? [Option(language: nil, name: Self.autoDetectTitle, nativeName: nil)] + languages
            : languages
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = mode.title
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Language")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        options.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Language", for: indexPath)
        let option = options[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = option.name
        if let language = option.language, let nativeName = option.nativeName, nativeName != option.name {
            // VoiceOver reads the native name in its own language.
            content.secondaryAttributedText = NSAttributedString(
                string: nativeName,
                attributes: [
                    .accessibilitySpeechLanguage: language.rawValue,
                    .font: UIFont.preferredFont(forTextStyle: .subheadline),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            )
        }
        cell.contentConfiguration = content
        let isCurrent = current == option.language
        cell.accessoryType = isCurrent ? .checkmark : .none
        if isCurrent {
            cell.accessibilityTraits.insert(.selected)
        } else {
            cell.accessibilityTraits.remove(.selected)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelect(options[indexPath.row].language)
        navigationController?.popViewController(animated: true)
    }
}
