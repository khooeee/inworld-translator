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
        // Listening is paused while the phone talks.
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

/// A horizontal bar showing how loud the microphone input is.
final class LevelMeterView: UIView {
    private let fill = UIView()
    private var fillWidth: NSLayoutConstraint!
    private var level: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 3
        clipsToBounds = true
        fill.backgroundColor = .systemGreen
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)
        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            fillWidth,
            heightAnchor.constraint(equalToConstant: 6),
        ])

        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Microphone level")
        accessibilityTraits = .updatesFrequently
        reset()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func set(level newLevel: Float) {
        // Rise quickly, fall slowly, like a VU meter, so speech reads as steady.
        let target = CGFloat(max(0, min(1, newLevel)))
        show(target > level ? target : max(target, level * 0.8))
    }

    /// Empties the meter at once, for when the microphone is released.
    func reset() {
        show(0)
    }

    private func show(_ newLevel: CGFloat) {
        level = newLevel
        fillWidth.constant = bounds.width * level
        accessibilityValue = switch level {
        case ..<0.05: String(localized: "Silent")
        case ..<0.35: String(localized: "Low")
        case ..<0.7: String(localized: "Medium")
        default: String(localized: "High")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fillWidth.constant = bounds.width * level
    }
}

/// A message about why listening stopped or degraded, with an optional fix.
final class NoticeView: UIView {
    private let label = UILabel()
    private let actionButton = UIButton(configuration: .borderless())
    private let closeButton = UIButton(configuration: .plain())

    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12

        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0

        actionButton.configuration?.contentInsets = .zero
        actionButton.titleLabel?.adjustsFontForContentSizeCategory = true
        actionButton.contentHorizontalAlignment = .leading
        actionButton.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .primaryActionTriggered)

        closeButton.configuration?.image = UIImage(systemName: "xmark.circle.fill")
        closeButton.configuration?.baseForegroundColor = .tertiaryLabel
        closeButton.accessibilityLabel = String(localized: "Dismiss")
        closeButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .primaryActionTriggered)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let text = UIStackView(arrangedSubviews: [label, actionButton])
        text.axis = .vertical
        text.spacing = 4
        text.alignment = .leading
        let row = UIStackView(arrangedSubviews: [text, closeButton])
        row.spacing = 8
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ notice: TranslationViewModel.Notice) {
        label.text = notice.message
        switch notice.action {
        case .openSystemSettings:
            actionButton.configuration?.title = String(localized: "Open Settings")
            actionButton.isHidden = false
        case .openAPIKeySettings:
            actionButton.configuration?.title = String(localized: "Add API Key")
            actionButton.isHidden = false
        case nil:
            actionButton.isHidden = true
        }
    }
}
