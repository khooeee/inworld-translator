import CoreMedia
import TranslatorCore
import UIKit

/// Renders compact captions into a reusable pixel buffer for Picture in Picture.
@MainActor
struct CaptionFrame {
    static let aspectRatio: CGFloat = CGFloat(width) / CGFloat(height)

    private static let width = 640
    private static let height = 360
    private static let padding: CGFloat = 24
    private static let rowGap: CGFloat = 12
    private static let lineGap: CGFloat = 4
    private static let textWidth = CGFloat(width) - 2 * padding

    struct Content: Equatable {
        let rows: [Row]
        let emptyText: String
    }

    struct Row: Equatable {
        let original: String
        let translation: String?
        let isTranslating: Bool
        let isSpeaking: Bool

        init(phrase: Phrase, isSpeaking: Bool) {
            original = phrase.sourceText
            self.isSpeaking = isSpeaking
            if phrase.isSpokenInTargetLanguage {
                translation = nil
                isTranslating = false
            } else {
                switch phrase.translation {
                case .pending:
                    translation = String(localized: "Translating…")
                    isTranslating = true
                case .partial(let text):
                    translation = text
                    isTranslating = true
                case .completed(let text):
                    translation = text
                    isTranslating = false
                case .none, .unavailable:
                    translation = nil
                    isTranslating = false
                }
            }
        }
    }

    private let pixels: CVPixelBuffer
    private let format: CMVideoFormatDescription

    init?(content: Content) {
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, Self.width, Self.height, kCVPixelFormatType_32BGRA, attributes, &pixels) == kCVReturnSuccess,
              let pixels, Self.draw(content, in: pixels) else { return nil }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                            formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        self.pixels = pixels
        self.format = format
    }

    func makeSampleBuffer() -> CMSampleBuffer? {
        // An unsynchronized display layer presents timestamps on the host clock.
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 4),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // Each frame is a live snapshot. A newer caption can replace a queued frame.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           let entry = CFArrayGetValueAtIndex(attachments, 0) {
            let dictionary = Unmanaged<CFMutableDictionary>.fromOpaque(entry).takeUnretainedValue()
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private static func draw(_ content: Content, in pixels: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else { return false }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        UIColor(white: 0.08, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))
        if content.rows.isEmpty {
            let text = Text(content.emptyText, size: 28, weight: .semibold, color: .white)
            text.draw(y: max(padding, (CGFloat(height) - text.height) / 2), height: text.height)
        } else {
            drawRows(content.rows)
        }
        return true
    }

    private static func drawRows(_ rows: [Row]) {
        let usableHeight = CGFloat(height) - 2 * padding
        var remaining = usableHeight
        var visible: [Layout] = []
        for row in rows.reversed() {
            var layout = Layout(row: row)
            if visible.isEmpty { layout.fit(in: usableHeight) }
            guard layout.height <= remaining else { break }
            visible.append(layout)
            remaining -= layout.height + rowGap
        }

        var y = padding
        for (index, layout) in visible.reversed().enumerated() {
            if index > 0 {
                UIColor(white: 0.32, alpha: 1).setFill()
                UIRectFill(CGRect(x: padding, y: y - rowGap / 2, width: textWidth, height: 1))
            }
            if layout.isSpeaking {
                let highlight = CGRect(x: padding / 2, y: y - 4, width: textWidth + padding, height: layout.height + 8)
                UIColor(red: 0.10, green: 0.25, blue: 0.44, alpha: 1).setFill()
                UIBezierPath(roundedRect: highlight, cornerRadius: 8).fill()
            }
            layout.original.draw(y: y, height: layout.originalHeight)
            layout.translation?.draw(y: y + layout.originalHeight + lineGap, height: layout.translationHeight)
            y += layout.height + rowGap
        }
    }

    @MainActor
    private struct Layout {
        let original: Text
        let translation: Text?
        let isSpeaking: Bool
        var originalHeight: CGFloat
        var translationHeight: CGFloat
        var height: CGFloat { originalHeight + translationHeight + (translation == nil ? 0 : CaptionFrame.lineGap) }

        init(row: Row) {
            original = row.translation == nil
                ? Text(row.original, size: 32, weight: .semibold, color: .white)
                : Text(row.original, size: 24, weight: .regular, color: UIColor(white: 0.8, alpha: 1))
            if let text = row.translation {
                translation = row.isTranslating
                    ? Text(text, size: 28, weight: .regular, color: UIColor(white: 0.8, alpha: 1))
                    : Text(text, size: 32, weight: .semibold, color: .white)
            } else {
                translation = nil
            }
            isSpeaking = row.isSpeaking
            originalHeight = original.height
            translationHeight = translation?.height ?? 0
        }

        /// Keeps both halves readable even when the newest phrase fills the window.
        mutating func fit(in availableHeight: CGFloat) {
            guard height > availableHeight else { return }
            guard translation != nil else {
                originalHeight = availableHeight
                return
            }
            let textHeight = availableHeight - CaptionFrame.lineGap
            let originalShare = min(originalHeight, floor(textHeight * 0.4))
            translationHeight = min(translationHeight, textHeight - originalShare)
            originalHeight = min(originalHeight, textHeight - translationHeight)
        }
    }

    @MainActor
    private struct Text {
        let value: NSAttributedString
        let height: CGFloat

        init(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .natural
            paragraph.lineBreakMode = .byWordWrapping
            value = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
            height = ceil(value.boundingRect(with: CGSize(width: CaptionFrame.textWidth, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        }

        func draw(y: CGFloat, height: CGFloat) {
            value.draw(with: CGRect(x: CaptionFrame.padding, y: y, width: CaptionFrame.textWidth, height: height),
                       options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        }
    }
}
