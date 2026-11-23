import TranslatorCore
import UIKit

/// The rate spoken translations are read at, from slowest to fastest.
final class SpeechSpeedViewController: UITableViewController {
    private static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5]

    private let preference: SpeechSpeedPreference

    init(preference: SpeechSpeedPreference) {
        self.preference = preference
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Speed")
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Speed")
    }

    private static func label(for rate: Double) -> String {
        let number = rate.formatted(.number.precision(.fractionLength(0...2)))
        return "\(number)×"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "Applies to the next translation spoken. Below 0.8× the voice may sound less natural.")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Self.rates.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Speed", for: indexPath)
        let rate = Self.rates[indexPath.row]
        let isSelected = abs(rate - preference.rate) < 0.001
        var content = UIListContentConfiguration.valueCell()
        content.text = Self.label(for: rate)
        if rate == InworldClient.Configuration.defaultSpeakingRate {
            content.secondaryText = String(localized: "Normal")
        }
        cell.contentConfiguration = content
        cell.accessoryType = isSelected ? .checkmark : .none
        cell.accessibilityLabel = String(localized: "Speed \(Self.label(for: rate))")
        if isSelected {
            cell.accessibilityTraits.insert(.selected)
        } else {
            cell.accessibilityTraits.remove(.selected)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        preference.select(Self.rates[indexPath.row])
        tableView.deselectRow(at: indexPath, animated: true)
        tableView.reloadData()
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Speed \(Self.label(for: Self.rates[indexPath.row]))"))
    }
}
