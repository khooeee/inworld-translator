import TranslatorCore
import UIKit

/// Shows the Inworld STT-1 language catalog or lets the user choose a target.
final class SupportedLanguagesViewController: UITableViewController {
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
    private let selection: (current: TargetLanguage, choose: (TargetLanguage) -> Void)?

    init(selection: (current: TargetLanguage, choose: (TargetLanguage) -> Void)? = nil) {
        self.selection = selection
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = selection == nil ? String(localized: "Supported Languages") : String(localized: "Translate to")
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Language")
        tableView.allowsSelection = selection != nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        languages.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard selection == nil else { return nil }
        return String(localized: "Speak any of these \(languages.count) languages. The app detects which one automatically and follows switches mid-conversation.")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard selection == nil else { return nil }
        return String(localized: "Speech recognition is by Inworld STT-1. Very short phrases are sometimes detected as the wrong language.")
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
        let isCurrent = selection?.current == language.target
        cell.accessoryType = isCurrent ? .checkmark : .none
        if isCurrent {
            cell.accessibilityTraits.insert(.selected)
        } else {
            cell.accessibilityTraits.remove(.selected)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let selection else { return }
        selection.choose(languages[indexPath.row].target)
        navigationController?.popViewController(animated: true)
    }
}
