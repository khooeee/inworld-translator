import UIKit

/// A rounded bubble with the same opposing tails as the app icon.
final class SpeechBubbleView: UIView {
    enum Tail {
        case leading
        case trailing
    }

    var strokeColor: UIColor? { didSet { setNeedsDisplay() } }
    private let fillColor: UIColor
    private let tail: Tail

    init(tail: Tail, fill: UIColor, stroke: UIColor? = nil) {
        self.tail = tail
        fillColor = fill
        strokeColor = stroke
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitLayoutDirection.self]) { (view: SpeechBubbleView, _) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        let body = bounds.insetBy(dx: 6, dy: 1)
        guard body.width > 16, body.height > 14 else { return }
        let left = body.minX
        let right = body.maxX
        let top = body.minY
        let bottom = body.maxY - 6
        let radius = min(20, (bottom - top) / 2, body.width / 4)

        let path = UIBezierPath()
        path.move(to: CGPoint(x: left + radius, y: top))
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + radius), controlPoint: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), controlPoint: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left - 4, y: bottom + 5), controlPoint: CGPoint(x: left + 11, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - radius / 2), controlPoint: CGPoint(x: left, y: bottom - 1))
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: top), controlPoint: CGPoint(x: left, y: top))
        path.close()

        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        if (tail == .trailing) != rightToLeft {
            path.apply(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: bounds.midX * 2, ty: 0))
        }
        fillColor.setFill()
        path.fill()
        if let strokeColor {
            strokeColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
