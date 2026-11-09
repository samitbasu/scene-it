import AppKit
import SceneItCore
import SwiftUI

/// The page (PLAN §4.3, §6): a TextKit 2 text view that draws itself as a white US Letter page
/// with 1 in margins on the gray desk, and grows downward as the scene does. It holds the
/// scene's body only (decision 0015); its `SceneTextEditor` keeps it in step with the model.
final class ManuscriptTextView: SceneTextView {
    weak var focus: PageFocus?

    static func page(editability: @escaping () -> Editability) -> ManuscriptTextView {
        let view = ManuscriptTextView(editability: editability)
        view.configure(.body)
        view.drawsBackground = true
        view.textLayoutManager?.delegate = view.underliner
        view.backgroundColor = NSColor(WindowMetrics.deskColor)
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

    // MARK: Comments (ADR 0032): on the page alone

    /// Lays the text out with its comments underlined.
    private let underliner = CommentUnderliner()

    /// The comments underlined, as the scene has them.
    var commentPalette: CommentPalette {
        get { underliner.palette }
        set { redraw(underliner.show(newValue, laidOutBy: textLayoutManager)) }
    }

    /// Draws again the paragraphs that hold `ranges`, and nothing else. TextKit 2 draws each
    /// paragraph into a view of its own and keeps that drawing when only the fragment's layout is
    /// invalidated (it keeps the fragment, in the same frame), so the paragraphs would go on
    /// showing their old underlines until something else redrew them (the owner's bug, #25). The
    /// views that draw them are marked, over the paragraphs' drawing surfaces only.
    /// No paragraph is skipped for being off screen: TextKit keeps the views it drew paragraphs
    /// in past the visible edge (its viewport's overdraw, and after a scroll), and a paragraph
    /// with no view of its own costs only the intersections below.
    private func redraw(_ ranges: [NSTextRange]) {
        guard !ranges.isEmpty, let layout = textLayoutManager else { return }
        let origin = textContainerOrigin
        var paragraphs: Set<ObjectIdentifier> = []
        var surfaces: [NSRect] = []
        for range in ranges {
            layout.enumerateTextLayoutFragments(from: range.location, options: []) { fragment in
                guard fragment.rangeInElement.location.compare(range.endLocation) == .orderedAscending else {
                    return false
                }
                // One comment's runs often share a paragraph.
                guard paragraphs.insert(ObjectIdentifier(fragment)).inserted else { return true }
                let frame = fragment.layoutFragmentFrame
                // With the room below the last line, where underlines a dismissed comment took
                // with it were drawn, outside the paragraph's surface now.
                var surface = fragment.renderingSurfaceBounds.union(CGRect(origin: .zero, size: frame.size))
                surface.size.height += ParagraphRole.doubleSpacingGap
                surfaces.append(surface.offsetBy(dx: frame.minX + origin.x, dy: frame.minY + origin.y))
                return true
            }
        }
        guard !surfaces.isEmpty else { return }
        for view in subviewTree(of: self) where view !== self && view !== commentButton {
            for surface in surfaces {
                let local = view.convert(surface, from: self).intersection(view.bounds)
                if !local.isEmpty { view.setNeedsDisplay(local) }
            }
        }
    }

    /// A click on commented text, or on its underlines, selects its comment (PLAN §8.1), once
    /// it has placed the caret as any click does.
    override func mouseDown(with event: NSEvent) {
        let pressed = CommentPress.character(pressedBy: event, in: self)
        super.mouseDown(with: event)
        if let pressed, CommentPress.selectsComment(leaving: selectedRange()) {
            editor?.clickedComments(at: pressed)
        }
    }

    // MARK: The floating Comment button (PLAN §8.1)

    /// At the end of the selection while the page can take a new comment
    /// (`EditorFormatting.commentablePage`), and not while a selection is being dragged out.
    private(set) lazy var commentButton: CommentButton = {
        let button = CommentButton { [weak self] in
            self?.editor?.formatting.commentablePage?.newCommentInItsCard()
        }
        button.isHidden = true
        addSubview(button)
        return button
    }()

    /// The button before the text, wherever it shows, so a press on it never reaches the text
    /// view, which would collapse the selection and hide the button before its click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if !commentButton.isHidden, commentButton.frame.contains(convert(point, from: superview)) {
            return commentButton
        }
        return super.hitTest(point)
    }

    /// The text view sets the I-beam as the pointer moves; over the button, it's the button's.
    override func mouseMoved(with event: NSEvent) {
        guard !isOverCommentButton(event) else { return NSCursor.pointingHand.set() }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard !isOverCommentButton(event) else { return NSCursor.pointingHand.set() }
        super.cursorUpdate(with: event)
    }

    private func isOverCommentButton(_ event: NSEvent) -> Bool {
        !commentButton.isHidden && commentButton.frame.contains(convert(event.locationInWindow, from: nil))
    }
    private var isStillSelecting = false

    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool
    ) {
        isStillSelecting = stillSelectingFlag
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
    }

    override func refreshSelectionBands() {
        super.refreshSelectionBands()
        placeCommentButton()
    }

    /// Shows the button below the end of the selection's last visible line, or hides it.
    func placeCommentButton() {
        guard let editor, editor.formatting.commentablePage === editor, !isStillSelecting,
            let end = selectionBands.last
        else {
            if !commentButton.isHidden { commentButton.isHidden = true }
            return
        }
        let size = commentButton.intrinsicContentSize
        let page = pageRect
        let x = min(max(end.maxX + 4, page.minX), page.maxX - size.width)
        let frame = NSRect(origin: NSPoint(x: x, y: end.maxY + 2), size: size)
        if commentButton.frame != frame { commentButton.frame = frame }
        commentButton.isHidden = false
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
        // The body's double spacing is below each line (ADR 0034), so the first line starts that
        // much lower, where the spacing above it used to put it.
        let inset = NSSize(
            width: page.minX + WindowMetrics.pageMargin,
            height: WindowMetrics.deskPadding + WindowMetrics.pageMargin + ParagraphRole.doubleSpacingGap)
        if textContainerInset != inset { textContainerInset = inset }
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
        drawSelectionBands(in: rect)
        drawSpokenSentence(in: rect)
    }

    // MARK: Read aloud (PLAN §10.3)

    /// The sentence being read aloud, as ranges of the text: drawn over the selection, and never
    /// in the text storage.
    var spoken: [NSRange] = [] {
        didSet {
            if spoken != oldValue { setNeedsDisplay(visibleRect) }
        }
    }

    /// The system's own colour for what Find shows: a default awaiting the owner's pick (#39).
    static let spokenSentenceColor = NSColor.findHighlightColor

    private func drawSpokenSentence(in rect: NSRect) {
        let bands = bands(of: spoken.compactMap(textRange(of:))).filter { $0.intersects(rect) }
        guard !bands.isEmpty else { return }
        Self.spokenSentenceColor.setFill()
        for band in bands { band.fill() }
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

/// Which presses on the text select a comment: plain clicks only (the owner's call, #24).
enum CommentPress {
    /// The character an unmodified single press is on, or above the underline it's on; `nil` for
    /// a press with Shift, Command, Option or Control, a double press, or a press off the text.
    static func character(pressedBy event: NSEvent, in view: NSTextView) -> Int? {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        guard event.clickCount == 1, modifiers.isEmpty, let layout = view.textLayoutManager else {
            return nil
        }
        let point = view.convert(event.locationInWindow, from: nil)
        let origin = view.textContainerOrigin
        return CommentUnderlineFragment.character(
            at: CGPoint(x: point.x - origin.x, y: point.y - origin.y), in: layout)
    }

    /// Whether the press, done, was a click: a press that dragged out a selection selects no
    /// comment.
    static func selectsComment(leaving selection: NSRange) -> Bool {
        selection.length == 0
    }
}
