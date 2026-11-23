import UIKit

final class TranslationEmptyView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)

        let artwork = UIImageView(image: Self.makeArtwork())
        artwork.contentMode = .scaleAspectFit
        artwork.isAccessibilityElement = false

        let label = UILabel()
        label.text = String(localized: "Tap Start to listen.")
        label.font = TranslationTheme.rounded(.preferredFont(forTextStyle: .title3))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = TranslationTheme.secondaryText
        label.textAlignment = .center
        label.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [artwork, label])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let artworkHeight = artwork.heightAnchor.constraint(equalToConstant: 116)
        artworkHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: readableContentGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: readableContentGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            artworkHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func makeArtwork() -> UIImage {
        let tile = UIView(frame: CGRect(x: 0, y: 0, width: 132, height: 116))
        tile.layer.cornerRadius = 30
        tile.clipsToBounds = true
        let gradient = CAGradientLayer()
        gradient.frame = tile.bounds
        gradient.colors = [TranslationTheme.coral.cgColor, TranslationTheme.pink.cgColor, TranslationTheme.primary.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        tile.layer.addSublayer(gradient)

        let original = SpeechBubbleView(tail: .leading, fill: .white.withAlphaComponent(0.32))
        original.frame = CGRect(x: 10, y: 15, width: 75, height: 60)
        let translated = SpeechBubbleView(tail: .trailing, fill: .white)
        translated.frame = CGRect(x: 47, y: 44, width: 75, height: 60)
        tile.semanticContentAttribute = .forceLeftToRight
        tile.addSubview(original)
        tile.addSubview(translated)

        for (text, bubble, color) in [("あ", original, UIColor.white), ("A", translated, TranslationTheme.primary)] {
            let label = UILabel(frame: bubble.bounds.offsetBy(dx: 0, dy: -4))
            label.text = text
            label.font = TranslationTheme.rounded(.systemFont(ofSize: 27, weight: .heavy))
            label.textColor = color
            label.textAlignment = .center
            bubble.addSubview(label)
        }

        return UIGraphicsImageRenderer(bounds: tile.bounds).image { context in
            tile.layer.render(in: context.cgContext)
        }
    }
}
