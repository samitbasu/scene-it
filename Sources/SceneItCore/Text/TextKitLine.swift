import AppKit

/// One line as TextKit 2 lays it out, which isn't simply the font's metrics: TextKit rounds the
/// ascent and descent up to whole points.
enum TextKitLine {
    /// The height of a line of `font` in `style`.
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
        return height
    }
}
