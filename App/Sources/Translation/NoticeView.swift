import TranslatorCore
import UIKit

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
