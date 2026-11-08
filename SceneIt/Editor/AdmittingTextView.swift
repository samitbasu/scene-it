import AppKit

/// A `KeyboardTextView` for plain text that applies the character policy's veto as the page
/// does: a change it can't hold is refused, and its admitted reading is made instead as one
/// undoable change. The title field and File a Copy's tags and note use it.
class AdmittingTextView: KeyboardTextView {
    /// What the text may hold of a replacement string (`CharacterPolicy.admittedLine` and the
    /// like).
    let admit: (String) -> String
    /// Undo and Redo act on this when it's set (a scene's title history, the tag field's own),
    /// and otherwise on the window's.
    var history: UndoManager?
    /// Called with the text after every change it makes (typing, a paste, an undo): its own,
    /// and nothing else's. Unlike a delegate's `textDidChange`, which comes through the
    /// notification center keyed on the view's address, it can't reach anyone once cleared.
    var onChange: ((String) -> Void)?
    /// False once what the text edits stops taking edits (a detached book): every change is
    /// then refused with a beep, before the view shows it. The view itself stops being editable
    /// only when SwiftUI next updates it, and a keystroke in between would otherwise show and
    /// vanish.
    var acceptsEdits: () -> Bool = { true }
    private let content: NSTextContentStorage

    /// A TextKit 2 view whose container tracks its width.
    init(admitting admit: @escaping (String) -> String) {
        self.admit = admit
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        self.content = content
        super.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var undoManager: UndoManager? {
        history ?? super.undoManager
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?(string)
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?)
        -> Bool
    {
        guard acceptsEdits() else {
            NSSound.beep()
            return false
        }
        guard let strings = replacementStrings, let admitted = Self.corrected(strings, by: admit) else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        let ranges = affectedRanges.map(\.rangeValue)
        guard let storage = textStorage,
            super.shouldChangeText(inRanges: affectedRanges, replacementStrings: admitted)
        else { return false }
        let selection = selectedRanges.map(\.rangeValue)
        storage.beginEditing()
        for (range, string) in zip(ranges, admitted).reversed() {
            storage.replaceCharacters(in: range, with: string)
        }
        storage.endEditing()
        didChangeText()
        let edits = zip(ranges, admitted).map { Edit(range: $0, length: $1.utf16.count) }
        selectedRanges = Self.selection(selection, after: edits).map(NSValue.init(range:))
        return false
    }

    /// One for a text field (`AdmittingTextField`), with undo.
    static func fieldEditor(admitting admit: @escaping (String) -> String) -> AdmittingTextView {
        let editor = AdmittingTextView(admitting: admit)
        editor.isFieldEditor = true
        editor.allowsUndo = true
        return editor
    }
}

/// A single-line text field with a field editor of its own: an `AdmittingTextView`, so it has
/// no input method and keeps only what its policy admits (ADR 0028). The window's shared field
/// editor serves every other field, which shouldn't.
final class AdmittingTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    final class Cell: NSTextFieldCell {
        fileprivate(set) var editor: AdmittingTextView?

        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            editor ?? super.fieldEditor(for: controlView)
        }
    }

    /// As `NSTextField(string:)` makes one: editable, selectable, bezeled, scrolling sideways as
    /// the text grows (`init(frame:)` already gives its font). `lineBreakMode` is set before
    /// scrolling is, since setting it turns scrolling off.
    init(string: String, editor: AdmittingTextView, lineBreakMode: NSLineBreakMode) {
        super.init(frame: .zero)
        (cell as? Cell)?.editor = editor
        stringValue = string
        isEditable = true
        isSelectable = true
        isBezeled = true
        drawsBackground = true
        self.lineBreakMode = lineBreakMode
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    var editor: AdmittingTextView? {
        (cell as? Cell)?.editor
    }
}

extension NSScrollView {
    /// Makes `textView` its document: as wide as the scroll view, wrapping there, and growing
    /// downward with its text, so it scrolls once it's taller than the scroll view.
    func holdGrowingText(_ textView: NSTextView) {
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        documentView = textView
    }
}
