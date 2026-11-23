import TranslatorCore
import UIKit

/// A colored dot and a short description of the connection.
final class ConnectionStatusView: UIView {
    private let dot = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.layer.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [dot, label])
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        accessibilityLabel = String(localized: "Connection")
        show(.idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ status: SessionStatus, speaking: Bool = false) {
        let (text, color) = Self.describe(status, speaking: speaking)
        label.text = text
        dot.backgroundColor = color
        accessibilityValue = text
    }

    static func describe(_ status: SessionStatus, speaking: Bool = false) -> (String, UIColor) {
        if speaking, status == .listening {
            return (String(localized: "Speaking translation"), .systemBlue)
        }
        return switch status {
        case .idle: (String(localized: "Ready"), .systemGray)
        case .starting: (String(localized: "Connecting…"), .systemOrange)
        case .listening: (String(localized: "Listening"), .systemGreen)
        case .reconnecting: (String(localized: "Reconnecting…"), .systemOrange)
        case .waitingForNetwork: (String(localized: "Waiting for network…"), .systemRed)
        case .interrupted: (String(localized: "Paused while another app uses the microphone"), .systemOrange)
        case .finishing: (String(localized: "Finishing…"), .systemGray)
        }
    }
}
