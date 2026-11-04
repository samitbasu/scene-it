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
        insertionPointColor = .black
        textContainer?.lineFragmentPadding = 0
        typingAttributes = role.typingAttributes
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
