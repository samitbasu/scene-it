import AppKit
import SceneItCore

extension NSPasteboard.PasteboardType {
    static let pageClip = Self(PageClip.pasteboardType)
}

/// An editor of one of the open scene's formatted texts: the page (`ManuscriptTextView`) or the
/// notes. A `SceneTextEditor` keeps it in step with the model, and is the gate for everything
/// typed or pasted into it; the view hands it its focus, its pasteboard traffic and its edits.
class SceneTextView: KeyboardTextView {
    weak var editor: SceneTextEditor?
    /// The window's Esc and Tab.
    weak var keys: WindowKeys?
    /// Whether this view has the keyboard focus, as it last became or resigned first responder:
    /// inside `resignFirstResponder` the window's `firstResponder` is still this view.
    private(set) var keyboardFocus = KeyboardFocus.elsewhere {
        didSet {
            if keyboardFocus != oldValue { keyboardFocusDidChange() }
        }
    }
    /// How the text is displayed, which every replaced string takes.
    private(set) var role = ParagraphRole.body

    /// Sets up what every editor of scene text shares.
    func configure(_ role: ParagraphRole) {
        self.role = role
        isRichText = true
        importsGraphics = false
        allowsImageEditing = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isContinuousSpellCheckingEnabled = true
        usesFontPanel = false
        usesRuler = false
        usesInspectorBar = false
        // The selection is drawn as bands (ADR 0034), so the system's highlight has no colour.
        selectedTextAttributes = [:]
        textContainer?.lineFragmentPadding = 0
        typingAttributes = role.typingAttributes
    }

    /// The typing attributes take the style of the caret's paragraph. TextKit also lays out the
    /// empty line after a final paragraph break in them, so when their style changes that line is
    /// laid out again. (What's typed is restyled for its own paragraph as it's typed.)
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            guard let string = textStorage?.string as NSString? else {
                super.typingAttributes = newValue
                return
            }
            var attributes = newValue
            let style = role.paragraphStyle(
                for: ParagraphContent(ofParagraphAt: selectedRange().location, in: string))
            attributes[.paragraphStyle] = style
            let restyled = super.typingAttributes[.paragraphStyle] as? NSParagraphStyle != style
            super.typingAttributes = attributes
            if restyled, string.length > 0, let layout = textLayoutManager,
                let last = layout.location(layout.documentRange.endLocation, offsetBy: -1),
                let range = NSTextRange(location: last, end: layout.documentRange.endLocation)
            {
                layout.invalidateLayout(for: range)
                layout.ensureLayout(for: range)
                updateInsertionPointStateAndRestartTimer(false)
            }
        }
    }

    // MARK: The selection (ADR 0034)

    /// Where the selection's bands are drawn, in this view's coordinates.
    private(set) var selectionBands: [NSRect] = []
    /// Where the selection colour overrides a highlight, and in which colour.
    private var highlightOverride: (ranges: [NSRange], color: NSColor) = ([], .clear)
    /// Where the last refresh or colour change asked for display, for tests of what's redrawn.
    private(set) var invalidatedBands: [NSRect] = []
    private var windowObservers: [NSObjectProtocol] = []

    isolated deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The colour the system highlights a selection with: the accent colour while this view has
    /// the keyboard focus in the key window, grey otherwise.
    var selectionColor: NSColor {
        keyboardFocus == .here && window?.isKeyWindow == true
            ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
    }

    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        refreshSelectionBands()
    }

    /// TextKit lays out lazily, so a selected line can move with the selection unmoved.
    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        refreshSelectionBands()
    }

    private var focusOnArrival = false

    /// Takes the keyboard focus now, or, if SwiftUI hasn't put the view in a window yet, as
    /// soon as it does.
    func takeFocus() {
        if let window {
            window.makeFirstResponder(self)
        } else {
            focusOnArrival = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        if focusOnArrival {
            focusOnArrival = false
            window.makeFirstResponder(self)
        }
        windowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.selectionColorChanged() }
            }
        }
    }

    /// Redraws only where the bands were and are, so dragging a selection out never redraws the
    /// whole text.
    func refreshSelectionBands() {
        let ranges = visibleSelection()
        overrideHighlights(in: ranges)
        let bands = bands(of: ranges)
        guard bands != selectionBands else { return }
        let previous = Set(selectionBands.map(Band.init))
        let current = Set(bands.map(Band.init))
        selectionBands = bands
        invalidate(previous.symmetricDifference(current).map(\.rect))
    }

    private func invalidate(_ rects: [NSRect]) {
        invalidatedBands = rects
        for rect in rects { setNeedsDisplay(rect) }
    }

    /// A band as a set member: `NSRect` isn't `Hashable`.
    private struct Band: Hashable {
        let x, y, width, height: CGFloat

        init(_ rect: NSRect) {
            (x, y, width, height) = (rect.minX, rect.minY, rect.width, rect.height)
        }

        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }

    /// The page re-centres its text as the window's width changes.
    override var textContainerInset: NSSize {
        didSet { refreshSelectionBands() }
    }

    /// The focus or the window's key state changed, and the selection's colour with them.
    private func selectionColorChanged() {
        overrideHighlights(in: visibleSelection())
        invalidate(selectionBands)
    }

    /// What's selected within the viewport, the only part that can be drawn, so a long selection
    /// costs no more than a short one.
    private func visibleSelection() -> [NSTextRange] {
        guard let layout = textLayoutManager, let viewport = layout.textViewportLayoutController.viewportRange
        else { return [] }
        return layout.textSelections.flatMap(\.textRanges).compactMap { $0.intersection(viewport) }
    }

    func bands(of ranges: [NSTextRange]) -> [NSRect] {
        guard let layout = textLayoutManager else { return [] }
        let origin = textContainerOrigin
        return SelectionBands.bands(of: ranges, in: layout).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// A highlight is a background colour drawn over the bands, so where the selection covers one
    /// a rendering attribute draws the selection's colour in its place (the owner's pick, ADR 0034).
    /// They're set by character offsets, which an edit or a new scene can't leave pointing at the
    /// wrong text, and every one goes before new ones are set: no other code sets this attribute.
    private func overrideHighlights(in ranges: [NSTextRange]) {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
            let storage = textStorage
        else { return }
        let start = content.documentRange.location
        var highlighted: [NSRange] = []
        for range in ranges {
            let offsets = NSRange(
                location: content.offset(from: start, to: range.location),
                length: content.offset(from: range.location, to: range.endLocation))
            storage.enumerateAttribute(.backgroundColor, in: offsets) { value, run, _ in
                if value != nil { highlighted.append(run) }
            }
        }
        let color = selectionColor
        guard highlightOverride.ranges != highlighted || highlightOverride.color != color else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange)
        for range in highlighted.compactMap(textRange(of:)) {
            layout.addRenderingAttribute(.backgroundColor, value: color, for: range)
        }
        highlightOverride = (highlighted, color)
    }

    /// The text range of `offsets`, a range of the storage's UTF-16 offsets.
    func textRange(of offsets: NSRange) -> NSTextRange? {
        guard let content = textLayoutManager?.textContentManager,
            let from = content.location(content.documentRange.location, offsetBy: offsets.location),
            let to = content.location(from, offsetBy: offsets.length)
        else { return nil }
        return NSTextRange(location: from, end: to)
    }

    /// An edit can change what the same offsets hold, so the highlights are looked at afresh.
    /// Its paragraphs are restyled first, so whoever hears of the change sees them styled.
    override func didChangeText() {
        editor?.restyleEditedParagraphs()
        super.didChangeText()
        highlightOverride = ([], .clear)
        refreshSelectionBands()
    }

    /// Draws the selection's bands behind the text.
    func drawSelectionBands(in rect: NSRect) {
        let visible = selectionBands.filter { $0.intersects(rect) }
        guard !visible.isEmpty else { return }
        selectionColor.setFill()
        for band in visible { band.fill() }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawSelectionBands(in: rect)
    }

    /// Without a background of its own (the notes), the view never calls `drawBackground(in:)`.
    override func draw(_ dirtyRect: NSRect) {
        if !drawsBackground { drawSelectionBands(in: dirtyRect) }
        super.draw(dirtyRect)
    }

    // MARK: Focus

    enum KeyboardFocus {
        /// This view has it.
        case here
        case elsewhere
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { keyboardFocus = .here }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { keyboardFocus = .elsewhere }
        return resigned
    }

    /// The view is leaving the window, which takes its focus with it.
    func leaveKeyboardFocus() {
        keyboardFocus = .elsewhere
    }

    func keyboardFocusDidChange() {
        editor?.showFormatting()
        selectionColorChanged()
    }

    // MARK: Keys

    /// PLAN §8.4: Tab moves the focus on rather than typing a tab, which the text can't hold.
    override func insertTab(_ sender: Any?) {
        guard let keys else { return window?.selectNextKeyView(sender) ?? () }
        keys.tab(.forward, from: tabStop)
    }

    override func insertBacktab(_ sender: Any?) {
        guard let keys else { return super.insertBacktab(sender) }
        keys.tab(.backward, from: tabStop)
    }

    var tabStop: TabStop {
        role == .notes ? .panel : .page
    }

    /// Esc goes to the window first. Neither `NSTextView` nor `NSResponder` implements
    /// `cancelOperation(_:)`, so it's caught here, where the text view's own Esc still follows.
    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)),
            keys?.escape(from: .focusedView) == .handled
        {
            return
        }
        super.doCommand(by: selector)
    }

    // MARK: A review's page (ADR 0042)

    /// The text of a `.commentsOnly` view can't change, so its menu offers nothing that would
    /// change it or its styles: no Cut or Paste, and no Font, Substitutions, Transformations or
    /// Layout Orientation.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, editability() == .commentsOnly else { return menu }
        for item in menu.items where Self.changesText(item) {
            menu.removeItem(item)
        }
        Self.tidySeparators(of: menu)
        return menu
    }

    private static let textChangingActions: Set<Selector> = [
        #selector(cut(_:)), #selector(paste(_:)), #selector(pasteAsPlainText(_:)),
        #selector(pasteAsRichText(_:)),
        #selector(delete(_:)), #selector(NSFontManager.orderFrontFontPanel(_:)),
        #selector(NSFontManager.addFontTrait(_:)), #selector(underline(_:)),
        #selector(orderFrontSubstitutionsPanel(_:)), #selector(uppercaseWord(_:)),
        #selector(changeLayoutOrientation(_:)),
    ]

    private static func changesText(_ item: NSMenuItem) -> Bool {
        if let action = item.action, textChangingActions.contains(action) { return true }
        return item.submenu?.items.contains(where: changesText) ?? false
    }

    private static func tidySeparators(of menu: NSMenu) {
        var previousIsSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousIsSeparator {
                menu.removeItem(item)
            } else {
                previousIsSeparator = item.isSeparatorItem
            }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    /// Find has no Replace on a `.commentsOnly` view.
    override func performTextFinderAction(_ sender: Any?) {
        guard !refusesReplace(sender) else { return }
        super.performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)), refusesReplace(item) { return false }
        return super.validateUserInterfaceItem(item)
    }

    private static let replaceActions: Set<NSTextFinder.Action> = [
        .showReplaceInterface, .replace, .replaceAll, .replaceAndFind, .replaceAllInSelection,
    ]

    private func refusesReplace(_ sender: Any?) -> Bool {
        guard editability() == .commentsOnly, let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
            let action = NSTextFinder.Action(rawValue: tag)
        else { return false }
        return Self.replaceActions.contains(action)
    }

    // MARK: The pasteboard (decision 0017)

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.pageClip] + super.writablePasteboardTypes
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .pageClip else { return super.writeSelection(to: pboard, type: type) }
        guard let data = editor?.clipData(of: selectedRanges.map(\.rangeValue)) else { return false }
        return pboard.setData(data, forType: type)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        SceneTextEditor.readableTypes
    }

    /// Every paste arrives here, and goes through the codec and the character policy. (Nothing is
    /// dropped: ADR 0036.)
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        editor?.paste(from: pboard, type: type) ?? false
    }

    // MARK: Edits

    /// Replaces each range with its string as one undoable change, and puts the caret after the
    /// last. A string replacing text takes that text's format, comments included, as Find and
    /// Replace or a spelling correction would: the format of the first character it replaces,
    /// when it spans several runs. A string inserted at the caret takes the typing attributes.
    func replace(_ ranges: [NSRange], with strings: [String]) {
        guard let storage = textStorage, ranges.count == strings.count,
            shouldChangeText(inRanges: ranges.map(NSValue.init(range:)), replacementStrings: strings)
        else { return }
        let formats = ranges.map { range in
            range.length > 0 && range.location < storage.length
                ? role.attributes(normalizing: storage.attributes(at: range.location, effectiveRange: nil))
                : typingAttributes
        }
        let selection = selectedRanges.map(\.rangeValue)
        storage.beginEditing()
        for ((range, string), attributes) in zip(zip(ranges, strings), formats).reversed() {
            storage.replaceCharacters(
                in: range, with: NSAttributedString(string: string, attributes: attributes))
        }
        storage.endEditing()
        didChangeText()
        let edits = zip(ranges, strings).map { Edit(range: $0, length: $1.utf16.count) }
        selectedRanges = Self.selection(selection, after: edits).map(NSValue.init(range:))
    }
}
