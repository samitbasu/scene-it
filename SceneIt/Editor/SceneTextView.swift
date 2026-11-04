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
        // `CharacterPolicy` would only spell them in ASCII again.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        usesFontPanel = false
        usesRuler = false
        usesInspectorBar = false
        // The selection is drawn as bands (ADR 0034), so the system's highlight has no colour.
        selectedTextAttributes = [:]
        textContainer?.lineFragmentPadding = 0
        typingAttributes = role.typingAttributes
    }

    /// What's typed takes the style of the paragraph it's typed into. TextKit also lays out the
    /// empty line after a final paragraph break in the typing attributes, so when their style
    /// changes that line is laid out again.
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
                updateInsertionPointStateAndRestartTimer(false)
            }
        }
    }

    // MARK: The selection (ADR 0034)

    /// Where the selection's bands are drawn, in this view's coordinates.
    private(set) var selectionBands: [NSRect] = []
    /// Where a band ends when the selection goes on past its line.
    var selectionLineEnd = SelectionBands.LineEnd.trailingEdge {
        didSet { refreshSelectionBands() }
    }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        windowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.redrawSelectionBands() }
            }
        }
    }

    /// Redraws only where the bands were and are, so dragging a selection out never redraws the
    /// whole text.
    func refreshSelectionBands() {
        let bands = currentSelectionBands()
        guard bands != selectionBands else { return }
        let previous = selectionBands
        selectionBands = bands
        for band in previous where !bands.contains(band) { setNeedsDisplay(band) }
        for band in bands where !previous.contains(band) { setNeedsDisplay(band) }
    }

    private func redrawSelectionBands() {
        for band in selectionBands { setNeedsDisplay(band) }
    }

    private func currentSelectionBands() -> [NSRect] {
        guard let layout = textLayoutManager else { return [] }
        let ranges = layout.textSelections.flatMap(\.textRanges)
        let origin = textContainerOrigin
        return SelectionBands.bands(of: ranges, in: layout, lineEnd: selectionLineEnd).map {
            $0.offsetBy(dx: origin.x, dy: origin.y)
        }
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
        redrawSelectionBands()
    }

    // MARK: Keys

    /// PLAN §8.4: Tab moves the focus on rather than typing a tab, which the text can't hold.
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
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

    /// Every paste and drop arrives here, and goes through the codec and the character policy.
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
