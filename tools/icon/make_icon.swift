// Draws the app icon: a speech bubble in another language ("あ") answered by
// one in English ("A"), on a coral-to-magenta gradient. Writes a 1024 px
// opaque PNG into the app's asset catalog.
//
// Run from the repo root:  swift tools/icon/make_icon.swift

import AppKit
import UniformTypeIdentifiers

let size: CGFloat = 1024
let output = URL(fileURLWithPath: "App/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

enum TailSide { case left, right }

/// A speech bubble drawn as one outline. The tail replaces a bottom corner:
/// its outer edge continues the bubble's side down to a slightly rounded
/// point, and its inner edge sweeps back into the bottom edge.
func bubble(_ rect: NSRect, radius r: CGFloat, tail side: TailSide) -> NSBezierPath {
    let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    let k = r * 0.5523 // cubic control distance for a quarter circle
    let tailWidth = r * 0.62, tailDepth = r * 0.5, tipOut = r * 0.2, tipRound = r * 0.07
    let base = NSPoint(x: x0 + r * 0.45 + tailWidth, y: y1)
    let tip = NSPoint(x: x0 - tipOut, y: y1 + tailDepth)

    let path = NSBezierPath()
    path.move(to: NSPoint(x: x0 + r, y: y0))
    path.line(to: NSPoint(x: x1 - r, y: y0))
    path.curve(to: NSPoint(x: x1, y: y0 + r), controlPoint1: NSPoint(x: x1 - r + k, y: y0), controlPoint2: NSPoint(x: x1, y: y0 + r - k))
    path.line(to: NSPoint(x: x1, y: y1 - r))
    path.curve(to: NSPoint(x: x1 - r, y: y1), controlPoint1: NSPoint(x: x1, y: y1 - r + k), controlPoint2: NSPoint(x: x1 - r + k, y: y1))
    path.line(to: base)
    // Inner edge of the tail, to just short of the tip; then the rounded
    // tip; then the outer edge back up into the bubble's side.
    path.curve(to: NSPoint(x: tip.x + tipRound, y: tip.y - tipRound * 0.15), controlPoint1: NSPoint(x: base.x - tailWidth * 0.5, y: y1), controlPoint2: NSPoint(x: tip.x + tailWidth * 0.5, y: tip.y - tailDepth * 0.1))
    path.curve(to: NSPoint(x: tip.x + tipRound * 0.25, y: tip.y - tipRound * 0.9), controlPoint1: tip, controlPoint2: tip)
    path.curve(to: NSPoint(x: x0, y: y1 - r * 0.5), controlPoint1: NSPoint(x: x0 - tipOut * 0.25, y: y1 + tailDepth * 0.35), controlPoint2: NSPoint(x: x0, y: y1 - r * 0.08))
    path.line(to: NSPoint(x: x0, y: y0 + r))
    path.curve(to: NSPoint(x: x0 + r, y: y0), controlPoint1: NSPoint(x: x0, y: y0 + r - k), controlPoint2: NSPoint(x: x0 + r - k, y: y0))
    path.close()

    if side == .right {
        path.transform(using: AffineTransform(m11: -1, m12: 0, m21: 0, m22: 1, tX: rect.midX * 2, tY: 0))
    }
    return path
}

func drawCentered(_ text: String, font: NSFont, color: NSColor, at center: NSPoint) {
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let bounds = string.boundingRect(with: NSSize(width: size, height: size), options: [.usesLineFragmentOrigin, .usesFontLeading])
    string.draw(at: NSPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
}

func drawIcon() {
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)

    // Coral to magenta, with a warm glow at the top left.
    NSGradient(colors: [color(0xFF8A5B), color(0xF0457A), color(0xB8236E)])!
        .draw(in: NSBezierPath(rect: canvas), angle: -60)
    let glowCenter = NSPoint(x: 300, y: 250)
    NSGradient(colors: [color(0xFFD1A6, 0.35), color(0xFFD1A6, 0)])!
        .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 520, options: [])

    // Behind: what was said, in any language.
    color(0xFFFFFF, 0.28).setFill()
    bubble(NSRect(x: 128, y: 140, width: 500, height: 400), radius: 130, tail: .left).fill()
    let kana = NSFont(name: "HiraginoSans-W7", size: 250) ?? .boldSystemFont(ofSize: 250)
    drawCentered("あ", font: kana, color: .white, at: NSPoint(x: 378, y: 345))

    // In front: the English, lifted by a soft shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x5A0B33, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.shadowBlurRadius = 50
    shadow.set()
    NSColor.white.setFill()
    bubble(NSRect(x: 396, y: 420, width: 500, height: 400), radius: 130, tail: .right).fill()
    NSGraphicsContext.restoreGraphicsState()
    let heavy = NSFont.systemFont(ofSize: 290, weight: .heavy)
    let letter = heavy.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 290) } ?? heavy
    drawCentered("A", font: letter, color: color(0xD23673), at: NSPoint(x: 646, y: 625))
}

// App icons must be opaque: draw into an RGB context without alpha.
let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
// Top-left origin, so the layout above reads like UIKit.
context.translateBy(x: 0, y: size)
context.scaleBy(x: 1, y: -1)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
drawIcon()
NSGraphicsContext.restoreGraphicsState()

let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(output.path)") }
print("Wrote \(output.path)")
