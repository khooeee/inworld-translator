import UIKit

enum TranslationTheme {
    static let accent = adaptive(light: 0xA51C56, dark: 0xFFA9C7)
    static let primary = color(0xB8236E)
    static let stop = color(0xB82C29)
    static let coral = color(0xFF8A5B)
    static let pink = color(0xF0457A)
    static let canvas = adaptive(light: 0xFFF6F5, dark: 0x20151E)
    static let original = adaptive(light: 0xFFE3EB, dark: 0x482539)
    static let translated = adaptive(light: 0xFFFFFF, dark: 0x30222C)
    static let outline = adaptive(light: 0xEFD3DC, dark: 0x664354)
    static let secondaryText = adaptive(light: 0x75515F, dark: 0xDBB8C8)

    static let startBackground: UIImage = {
        let size = CGSize(width: 256, height: 48)
        let colors = [color(0xB5433D).cgColor, color(0xBB285D).cgColor, primary.cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil)
        return UIGraphicsImageRenderer(size: size).image { context in
            guard let gradient else { return }
            context.cgContext.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: []
            )
        }
    }()

    static func pill(fill: UIColor, foreground: UIColor) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = fill
        configuration.baseForegroundColor = foreground
        configuration.background.strokeColor = outline
        configuration.background.strokeWidth = 1
        return configuration
    }

    static func rounded(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
        let lightColor = color(light)
        let darkColor = color(dark)
        return UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor }
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: 1
        )
    }
}
