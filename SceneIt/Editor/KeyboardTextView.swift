import AppKit
import SceneItCore

/// Whether a text view's text takes changes.
enum Editability {
    case editable
    /// The text can't change, but comments on it can: a review's page (ADR 0042).
    case commentsOnly
    case readOnly

    /// As `book` takes `edit`: a detached (closed) book takes none.
    init(_ book: AppOpenBook?, for edit: EditKind) {
        self = book?.accepts(edit) == true ? .editable : .readOnly
    }

    /// The page's: its text is the manuscript, which a review takes only comments on.
    static func page(_ book: AppOpenBook?) -> Editability {
        guard let book else { return .readOnly }
        if book.accepts(.manuscript) { return .editable }
        return book.accepts(.annotations) ? .commentsOnly : .readOnly
    }
}

/// A text view with no input method (ADR 0028), for every editor of manuscript text: the page,
/// the title field and the notes. Keys reach it through the key bindings alone, as `insertText`,
/// so there's no dead key, press-and-hold accent or IME composition, and it never holds marked
/// text. Whatever it's given, its owner puts through the character policy. Text neither drops
/// into it nor drags out of it (ADR 0036): it arrives typed or pasted.
class KeyboardTextView: NSTextView {
    /// Asked before every change. What the view edits can stop taking edits (a book detached by
    /// Close Book or Open Other Version) before SwiftUI next updates the view, and a keystroke
    /// in between would show and then vanish, so the view refuses it, with a beep.
    let editability: () -> Editability
    /// The editor's own change of comments on the text, the one change a `.commentsOnly` view
    /// takes (`SceneTextEditor.rewrite`).
    var commentChange = CommentChange.none
    private let content: NSTextContentStorage

    enum CommentChange {
        case none, underWay
    }

    /// A TextKit 2 view whose container tracks its width. (`init(usingTextLayoutManager:)` can't
    /// be used: it calls `init(frame:textContainer:)` on the view, which a Swift subclass with
    /// an initializer of its own doesn't have.)
    init(editability: @escaping () -> Editability) {
        self.editability = editability
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        content.primaryTextLayoutManager = layout
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        self.content = content
        super.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool
    {
        switch editability() {
        case .editable:
            break
        case .commentsOnly where keepsText(affectedRanges.map(\.rangeValue), replacementStrings):
            break
        case .commentsOnly, .readOnly:
            NSSound.beep()
            return false
        }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    /// Whether a change is the editor's change of comments, or the undo or redo of one, and
    /// leaves the characters as they are. Anything else that changes only attributes (the
    /// system's Font menu, say) changes the copy's text and styles, and is refused.
    private func keepsText(_ ranges: [NSRange], _ replacements: [String]?) -> Bool {
        let undo = undoManager
        guard commentChange == .underWay || undo?.isUndoing == true || undo?.isRedoing == true else {
            return false
        }
        guard let replacements else { return true }
        let string = self.string as NSString
        return ranges.count == replacements.count
            && zip(ranges, replacements).allSatisfy { range, replacement in
                range.upperBound <= string.length
                    && string.substring(with: range).utf16.elementsEqual(replacement.utf16)
            }
    }

    override var inputContext: NSTextInputContext? {
        nil
    }

    /// Writing Tools rewrites text through paths the character policy's veto may never see, so
    /// it's off for good; setting it does nothing.
    override var writingToolsBehavior: NSWritingToolsBehavior {
        get { .none }
        set {}
    }

    // MARK: No drag and drop (ADR 0036)

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        []
    }

    override func updateDragTypeRegistration() {
        unregisterDraggedTypes()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        false
    }

    /// A press on the selection followed by a drag starts a drag here when presses go through
    /// `mouseDown`: always before macOS 27, and from it in a view that overrides `mouseDown`, as
    /// the page does.
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        false
    }

    /// From macOS 27 a text view that leaves `mouseDown` alone is its own
    /// `NSTextSelectionManager`'s delegate, and the manager asks it for the drag of a pressed
    /// selection; `NSTextView` doesn't declare the method, so this replaces it by its selector.
    /// `nil` means no drag.
    @available(macOS 27, *)
    @objc(selectionManager:makeDraggingSessionWithGesture:)
    func selectionManager(_ manager: NSTextSelectionManager, makeDraggingSession gesture: NSGestureRecognizer)
        -> NSDraggingSession?
    {
        nil
    }

    /// Without an input context nothing should call this; if anything does, its text is typed
    /// rather than marked, without the attributes marked text carries.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let plain = (string as? NSAttributedString)?.string ?? string
        insertText(plain, replacementRange: replacementRange)
    }

    /// The character policy's veto, for an editor to apply before every change: `strings` as
    /// `admit` leaves them, or `nil` if it leaves every one as it is.
    static func corrected(_ strings: [String], by admit: (String) -> String) -> [String]? {
        let admitted = strings.map(admit)
        // Code units, not `String ==`, which calls canonically equivalent strings equal.
        return zip(admitted, strings).contains { !$0.utf16.elementsEqual($1.utf16) } ? admitted : nil
    }

    /// A range of the text replaced with `length` characters.
    struct Edit {
        let range: NSRange
        let length: Int
    }

    /// `selection` once `edits` (in text order, not overlapping) are made: a selected range that
    /// is one of the edited ranges, as when typing over it, becomes a caret after its
    /// replacement; every other edge stays with the text around it.
    static func selection(_ selection: [NSRange], after edits: [Edit]) -> [NSRange] {
        func moved(_ position: Int) -> Int {
            var shift = 0
            for edit in edits {
                let range = edit.range
                if position >= range.upperBound {
                    shift += edit.length - range.length
                } else if position > range.location {
                    return range.location + shift + edit.length
                } else {
                    break
                }
            }
            return position + shift
        }
        return selection.map { range in
            if edits.contains(where: { $0.range == range }) {
                return NSRange(location: moved(range.upperBound), length: 0)
            }
            let start = moved(range.location)
            return NSRange(location: start, length: max(0, moved(range.upperBound) - start))
        }
    }
}
