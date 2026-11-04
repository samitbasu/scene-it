import AppKit
import Synchronization

/// One line as TextKit 2 lays it out, which isn't simply the font's metrics: TextKit rounds the
/// ascent and descent up to whole points.
enum TextKitLine {
    /// The height of a line of `font` in `style`; the font's own metrics, unrounded, if TextKit
    /// lays out no line.
    static func height(of font: NSFont, in style: NSParagraphStyle) -> CGFloat {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        layout.textContainer = NSTextContainer(size: NSSize(width: 1000, height: 1000))
        content.attributedString = NSAttributedString(
            string: "X", attributes: [.font: font, .paragraphStyle: style])
        var height: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
            height = $0.textLineFragments.first?.typographicBounds.height ?? 0
            return false
        }
        guard height > 0 else { return fallbackHeight(of: font, in: style) }
        return height
    }

    static func fallbackHeight(of font: NSFont, in style: NSParagraphStyle) -> CGFloat {
        if !reported.withLock({ $0.swap(true) }) {
            Log.editor.error("TextKit laid out no line to measure; using the font's metrics")
        }
        let multiple = style.lineHeightMultiple > 0 ? style.lineHeightMultiple : 1
        return (font.ascender - font.descender) * multiple + font.leading
    }

    private static let reported = Mutex(false)
}

extension Bool {
    /// Sets the value, and says what it was.
    fileprivate mutating func swap(_ value: Bool) -> Bool {
        defer { self = value }
        return self
    }
}
