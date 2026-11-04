import AppKit
import SceneItCore

/// The page's caret, as tall as a single-spaced line of the typing font wherever the double
/// spacing puts the line (ADR 0030). The text view's own caret fills the whole double-height
/// line and nothing public sizes it, so it's made clear and this one is shown instead.
final class CaretIndicator {
    let indicator = NSTextInsertionIndicator()
    private unowned let view: ManuscriptTextView
    private var windowObservers: [NSObjectProtocol] = []

    init(in view: ManuscriptTextView, color: NSColor) {
        self.view = view
        view.insertionPointColor = .clear
        indicator.color = color
        indicator.displayMode = .hidden
        view.addSubview(indicator)
    }

    isolated deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var frame: NSRect { indicator.frame }

    private(set) var isShown = false

    func update() {
        let frame = shownFrame
        isShown = frame != nil
        guard let frame else {
            indicator.displayMode = .hidden
            return
        }
        if indicator.frame != frame { indicator.frame = frame }
        if indicator.displayMode != .automatic { indicator.displayMode = .automatic }
    }

    /// Follows the key state of the window the view is now in.
    func observe(_ window: NSWindow?) {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let window {
            windowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                }
            }
        }
        update()
    }

    /// Where the caret is shown, or `nil` where there should be none: the selection is a single
    /// caret in an editable view that has the keyboard focus.
    private var shownFrame: NSRect? {
        guard view.isEditable, view.keyboardFocus == .here, view.window?.isKeyWindow == true,
            let layout = view.textLayoutManager, layout.textSelections.count == 1,
            let selection = layout.textSelections.first, selection.textRanges.count == 1,
            let caret = selection.textRanges.first, caret.isEmpty,
            let font = view.typingAttributes[.font] as? NSFont ?? view.font
        else { return nil }
        var options: NSTextLayoutManager.SegmentOptions = []
        if selection.affinity == .upstream { options.insert(.upstreamAffinity) }
        var found: (frame: CGRect, baseline: CGFloat)?
        // The text view places its own caret by the selection segment; the standard segment of an
        // empty range leaves out a first line's indent.
        layout.enumerateTextSegments(in: caret, type: .selection, options: options) { _, frame, baseline, _ in
            found = (frame, baseline)
            return false
        }
        guard let segment = found else { return nil }
        let line = SingleSpacedLine(font)
        let origin = view.textContainerOrigin
        return NSRect(
            x: origin.x + segment.frame.minX,
            y: origin.y + segment.frame.minY + segment.baseline - line.ascent,
            width: 0, height: line.height)
    }
}

/// How TextKit lays out one line in `font` with no paragraph style: as tall as a line of the
/// single-spaced notes, which isn't the font's own ascent, descent and leading (TextKit rounds).
struct SingleSpacedLine {
    let height: CGFloat
    /// From the top of the line to its baseline.
    let ascent: CGFloat

    init(_ font: NSFont) {
        if let known = Self.measured[font] {
            self = known
        } else if let laidOut = Self.layOut(font) {
            Self.measured[font] = laidOut
            self = laidOut
        } else {
            Log.editor.error("Couldn't lay out a line for the caret; using the font's metrics")
            self.init(metricsOf: font)
        }
    }

    /// The font's own metrics, unrounded: the caret's height if TextKit lays out no line.
    init(metricsOf font: NSFont) {
        height = font.ascender - font.descender + font.leading
        ascent = font.ascender
    }

    private init(height: CGFloat, ascent: CGFloat) {
        self.height = height
        self.ascent = ascent
    }

    private static func layOut(_ font: NSFont) -> SingleSpacedLine? {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        layout.textContainer = NSTextContainer(size: NSSize(width: 1000, height: 1000))
        content.attributedString = NSAttributedString(string: " ", attributes: [.font: font])
        var line: NSTextLineFragment?
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
            line = $0.textLineFragments.first
            return false
        }
        guard let line, line.typographicBounds.height > 0 else { return nil }
        return SingleSpacedLine(height: line.typographicBounds.height, ascent: line.glyphOrigin.y)
    }

    private static var measured: [NSFont: SingleSpacedLine] = [:]
}
