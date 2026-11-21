import TranslatorCore
import UIKit

final class TargetLanguagePickerViewController: UITableViewController {
    private struct Language {
        let target: TargetLanguage
        /// In the reader's language, e.g. "Japanese".
        let name: String
        /// In the language itself, e.g. "日本語".
        let nativeName: String
    }

    private let languages = TargetLanguage.allCases
        .map { language in
            Language(
                target: language,
                name: language.name(),
                nativeName: language.name(in: Locale(identifier: language.rawValue))
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    private let current: TargetLanguage
    private let onSelect: (TargetLanguage) -> Void

    init(current: TargetLanguage, onSelect: @escaping (TargetLanguage) -> Void) {
        self.current = current
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Translate to")
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Language")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        languages.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Language", for: indexPath)
        let language = languages[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = language.name
        if language.nativeName != language.name {
            // VoiceOver reads the native name in its own language.
            content.secondaryAttributedText = NSAttributedString(
                string: language.nativeName,
                attributes: [
                    .accessibilitySpeechLanguage: language.target.rawValue,
                    .font: UIFont.preferredFont(forTextStyle: .subheadline),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            )
        }
        cell.contentConfiguration = content
        let isCurrent = current == language.target
        cell.accessoryType = isCurrent ? .checkmark : .none
        if isCurrent {
            cell.accessibilityTraits.insert(.selected)
        } else {
            cell.accessibilityTraits.remove(.selected)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelect(languages[indexPath.row].target)
        navigationController?.popViewController(animated: true)
    }
}
