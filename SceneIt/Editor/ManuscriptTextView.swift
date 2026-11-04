import AppKit
import SceneItCore
import SwiftUI

/// The page (PLAN §4.3, §6): a TextKit 2 text view that draws itself as a white US Letter page
/// with 1 in margins on the gray desk, and grows downward as the scene does. It holds the
/// scene's body only (decision 0015); its `SceneTextEditor` keeps it in step with the model.
final class ManuscriptTextView: SceneTextView {
    weak var focus: PageFocus?
    /// Set up by `page()`, so `nil` only while the view is being created.
    private(set) var caret: CaretIndicator?

    static func page() -> ManuscriptTextView {
        let view = ManuscriptTextView(usingTextLayoutManager: true)
        view.configure(.body)
        view.drawsBackground = true
        view.backgroundColor = NSColor(WindowMetrics.deskColor)
        view.caret = CaretIndicator(in: view, color: .black)
        // The text column is always 6.5 in, however wide the view, so zoom and the window's
        // width never change a line break.
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.size = NSSize(
            width: WindowMetrics.textColumnWidth, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: WindowMetrics.pageSize.height + 2 * WindowMetrics.deskPadding)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        return view
    }

    // MARK: The page on the desk

    /// The white sheet, centred on the desk, as tall as the text needs and never shorter
    /// than a page.
    var pageRect: NSRect {
        let width = WindowMetrics.pageSize.width
        let x = max(WindowMetrics.deskPadding, (bounds.width - width) / 2)
        return NSRect(
            x: x, y: WindowMetrics.deskPadding, width: width,
            height: max(WindowMetrics.pageSize.height, bounds.height - 2 * WindowMetrics.deskPadding))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let page = pageRect
        let inset = NSSize(
            width: page.minX + WindowMetrics.pageMargin,
            height: WindowMetrics.deskPadding + WindowMetrics.pageMargin)
        if textContainerInset != inset { textContainerInset = inset }
        caret?.update()
    }

    override func drawBackground(in rect: NSRect) {
        backgroundColor.setFill()
        rect.fill()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(WindowMetrics.pageShadow.opacity)
        shadow.shadowBlurRadius = WindowMetrics.pageShadow.radius
        shadow.shadowOffset = NSSize(width: 0, height: -WindowMetrics.pageShadow.drop)
        shadow.set()
        NSColor.white.setFill()
        pageRect.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: The caret (ADR 0030)

    override func keyboardFocusDidChange() {
        super.keyboardFocusDidChange()
        caret?.update()
    }

    override var isEditable: Bool {
        didSet { caret?.update() }
    }

    /// The caret's height follows the typing font, which the editor sets after the selection moves.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        didSet { caret?.update() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        caret?.observe(window)
    }

    /// Where the text view moves its own (clear) caret, for every caret move and edit.
    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        caret?.update()
    }

    /// TextKit 2 lays out lazily, so a line can move after an edit or an estimate is replaced
    /// without the selection moving.
    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        caret?.update()
    }

    // MARK: Keys

    /// Shift-Tab at the very start of the body goes back to the title (decision 0015).
    override func insertBacktab(_ sender: Any?) {
        if selectedRange() == NSRange(location: 0, length: 0) {
            focus?.focusTitle()
        } else {
            super.insertBacktab(sender)
        }
    }
}
