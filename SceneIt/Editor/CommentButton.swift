import AppKit
import SceneItCore
import SwiftUI

/// The 💬 Comment pill the page shows below the end of a selection (mockup 02, the owner's pick,
/// #25). An AppKit button over the text: its whole frame takes the click, before the text view
/// can (`ManuscriptTextView.hitTest`), so the selection survives until the comment is made; it
/// takes the first click in an inactive window, and shows the pointing hand, not the I-beam.
final class CommentButton: NSButton {
    private static let margin: CGFloat = 3
    private static let padding = NSSize(width: 10, height: 4)

    init(action: @escaping () -> Void) {
        self.onPress = action
        super.init(frame: .zero)
        isBordered = false
        title = CommentWording.commentButton
        toolTip = CommentWording.commentButtonHelp(KeyboardShortcut.newComment.spelled)
        setAccessibilityLabel(CommentWording.newComment)
        target = self
        self.action = #selector(press(_:))
        setFrameSize(intrinsicContentSize)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) {
        nil
    }

    private let onPress: () -> Void

    @objc private func press(_ sender: Any?) {
        onPress()
    }

    private var label: NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black,
            ])
    }

    override var intrinsicContentSize: NSSize {
        let text = label.size()
        return NSSize(
            width: ceil(text.width) + 2 * (Self.padding.width + Self.margin),
            height: ceil(text.height) + 2 * (Self.padding.height + Self.margin))
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.15)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: isFlipped ? 1 : -1)
        shadow.set()
        (isHighlighted ? NSColor(white: 0.93, alpha: 1) : .white).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        let border = NSBezierPath(
            roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: pill.height / 2 - 0.5,
            yRadius: pill.height / 2 - 0.5)
        border.stroke()
        let text = label
        let size = text.size()
        text.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// The text view under it would show the I-beam.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}
