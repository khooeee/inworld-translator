import TranslatorCore
import UIKit

/// A horizontal bar showing how loud the microphone input is.
final class LevelMeterView: UIView {
    private let fill = UIView()
    private var fillWidth: NSLayoutConstraint!
    private var level: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TranslationTheme.outline
        layer.cornerRadius = 3
        clipsToBounds = true
        fill.backgroundColor = TranslationTheme.accent
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
