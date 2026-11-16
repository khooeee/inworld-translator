import UIKit

/// The languages the app can caption: those Inworld STT-1 recognizes.
final class SupportedLanguagesViewController: UITableViewController {
    /// Speech recognition languages of `inworld/inworld-stt-1`, from
    /// https://docs.inworld.ai/stt/languages (checked November 2026).
    /// Translation covers far more; recognition is the limit.
    static let codes = [
        "ar", "yue", "zh", "cs", "da", "nl", "en", "fil", "fi", "fr",
        "de", "el", "hi", "hu", "id", "it", "ja", "ko", "mk", "ms",
        "fa", "pl", "pt", "ro", "ru", "es", "sv", "th", "tr", "vi",
    ]

    struct Language {
        let code: String
        /// In the reader's language, e.g. "Japanese".
        let name: String
        /// In the language itself, e.g. "日本語".
        let nativeName: String
    }

    static func languages(in locale: Locale = .current) -> [Language] {
        codes
            .map { code in
                Language(
                    code: code,
                    name: locale.localizedString(forLanguageCode: code) ?? code,
                    nativeName: Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private let languages = SupportedLanguagesViewController.languages()

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Supported Languages")
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Language")
        tableView.allowsSelection = false
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        languages.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        String(localized: "Speak any of these \(languages.count) languages. The app detects which one automatically, follows switches mid-conversation, and shows the English.")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "English is shown as spoken, without a translation. Speech recognition is by Inworld STT-1; other languages may come out garbled. Very short phrases are sometimes detected as the wrong language.")
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
                    .accessibilitySpeechLanguage: language.code,
                    .font: UIFont.preferredFont(forTextStyle: .subheadline),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            )
        }
        cell.contentConfiguration = content
        return cell
    }
}
