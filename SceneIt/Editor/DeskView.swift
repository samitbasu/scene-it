import AppKit
import SceneItCore

/// The gray desk the page lies on (PLAN §4.3): a scroll view that magnifies (PLAN §4.1).
///
/// The page is never narrower than the whole sheet on its desk, so the sheet can always be
/// scrolled into view. (Its text column is a fixed 6.5 in, so zoom never changes a line break.)
final class DeskView: NSScrollView {
    /// Called when a pinch ends, with the zoom it ended at.
    var pinched: (Zoom) -> Void = { _ in }
    private var isPinching = false

    /// The sheet and the desk around it: the narrowest the page ever is.
    static let deskWidth = WindowMetrics.pageSize.width + 2 * WindowMetrics.deskPadding
    private static let widthTolerance: CGFloat = 0.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowsMagnification = true
        minMagnification = ZoomBounds.range.lowerBound
        maxMagnification = ZoomBounds.range.upperBound
        contentView.postsBoundsChangedNotifications = true
        contentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            center.addObserver(self, selector: #selector(visibleAreaChanged), name: name, object: contentView)
        }
        center.addObserver(
            self, selector: #selector(pinchBegan), name: NSScrollView.willStartLiveMagnifyNotification,
            object: self)
        center.addObserver(
            self, selector: #selector(pinchEnded), name: NSScrollView.didEndLiveMagnifyNotification,
            object: self)
    }

    required init?(coder: NSCoder) {
        fatalError("DeskView isn't loaded from a nib")
    }

    var zoom: Zoom {
        Zoom(clamping: magnification)
    }

    /// Shows the page at `zoom`, keeping the middle of what's visible in place. A pinch in
    /// progress wins until it ends.
    func show(_ zoom: Zoom) {
        guard !isPinching, zoom != self.zoom else { return }
        let visible = contentView.documentVisibleRect
        setMagnification(Double(zoom), centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        fitDocumentWidth()
    }

    /// The zoom at which the sheet and its desk fill the visible width. A page that wide is
    /// taller than the desk, so it allows for the vertical scroller, which takes width from
    /// the desk unless scrollers overlay the content.
    var fitWidthZoom: Zoom {
        let visible = Self.contentSize(
            forFrameSize: frame.size, horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self,
            borderType: borderType, controlSize: .regular, scrollerStyle: scrollerStyle)
        return Zoom(clamping: visible.width / Self.deskWidth)
    }

    @objc private func visibleAreaChanged() {
        fitDocumentWidth()
    }

    /// As wide as the visible desk, so the page stays centred, but never narrower than the
    /// whole sheet on its desk. The width is rounded down, and one a rounding error short of
    /// the sheet's (as at Fit Width) is used as it is: AppKit's own sum of the visible width
    /// can come out a fraction smaller than ours, and a page a fraction too wide shows a
    /// horizontal scroller.
    private func fitDocumentWidth() {
        guard let page = documentView else { return }
        let visible = contentView.bounds.width
        let width = visible > Self.deskWidth - Self.widthTolerance ? visible.rounded(.down) : Self.deskWidth
        if page.frame.width != width { page.setFrameSize(NSSize(width: width, height: page.frame.height)) }
    }

    @objc private func pinchBegan() {
        isPinching = true
    }

    @objc private func pinchEnded() {
        isPinching = false
        pinched(zoom)
    }

    // MARK: The find bar's field, a Tab stop and an Esc layer (PLAN §8.4)

    /// The window's Esc and Tab, which the find bar's field asks.
    weak var keys: WindowKeys?
    private var findFieldKeys: FindFieldKeys?

    override var isFindBarVisible: Bool {
        didSet { routeFindFieldKeys() }
    }

    override func findBarViewDidChangeHeight() {
        super.findBarViewDidChangeHeight()
        routeFindFieldKeys()
    }

    /// Whether the find bar's field sends its Tab and Esc to the window's keys.
    var findFieldRoutesKeys: Bool {
        findField?.delegate is FindFieldKeys
    }

    /// The find bar's field may be built after it shows; laying out the bar finds it.
    override func tile() {
        super.tile()
        routeFindFieldKeys()
    }

    var findField: NSSearchField? {
        guard isFindBarVisible, let bar = findBarView else { return nil }
        func fields(in view: NSView) -> [NSSearchField] {
            (view as? NSSearchField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        return fields(in: bar).first
    }

    func focusFindField() -> Bool {
        guard let field = findField, let window, !field.isHiddenOrHasHiddenAncestor else { return false }
        routeFindFieldKeys()
        return window.makeFirstResponder(field)
    }

    /// The field's delegate is the find bar's own; Tab, Shift-Tab and Esc are asked of the
    /// window first, and everything else passes through.
    private func routeFindFieldKeys() {
        guard let field = findField, !(field.delegate is FindFieldKeys) else { return }
        let routed = FindFieldKeys(finderDelegate: field.delegate) { [weak self] key in
            guard let keys = self?.keys else { return false }
            switch key {
            case .tab(let direction): return keys.tab(direction, from: .searchField)
            case .escape: return keys.escape(from: .focusedView) == .handled
            }
        }
        findFieldKeys = routed
        field.delegate = routed
    }
}

/// Stands in as the find bar field's delegate: Tab, Shift-Tab and Esc go to the window's keys;
/// every other message goes to the find bar's own delegate.
private final class FindFieldKeys: NSObject, NSSearchFieldDelegate {
    enum Key {
        case tab(TabDirection)
        case escape
    }

    /// `nonisolated(unsafe)` because `responds(to:)` and `forwardingTarget(for:)` override
    /// `NSObject`'s nonisolated methods. Only AppKit calls them, as it sends the field's
    /// delegate messages, which it does on the main thread, the same thread that sets this once
    /// in `init`.
    nonisolated(unsafe) private weak var finderDelegate: (any NSTextFieldDelegate)?
    private let route: (Key) -> Bool

    init(finderDelegate: (any NSTextFieldDelegate)?, route: @escaping (Key) -> Bool) {
        self.finderDelegate = finderDelegate
        self.route = route
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)) where route(.tab(.forward)): return true
        case #selector(NSResponder.insertBacktab(_:)) where route(.tab(.backward)): return true
        case #selector(NSResponder.cancelOperation(_:)) where route(.escape): return true
        default: return finderDelegate?.control?(control, textView: textView, doCommandBy: selector) ?? false
        }
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || finderDelegate?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        finderDelegate
    }
}
