import AppKit
import SceneItCore

/// Keeps the page's text storage a mirror of the open scene's body, which is the one source
/// of truth: the storage is rebuilt from the model when the scene (or its body, from
/// elsewhere) changes, and every edit to the storage reaches the model in the same main-actor
/// turn, as the paragraphs it touched (`BodyChange`), so autosave hears of it at once.
///
/// It's the gate for what the writer types and pastes: the character policy (ADR 0022), the
/// codec's rules for pasted text (decision 0016), comments that never spread by typing
/// (PLAN §8.1), and the app's own pasteboard type (decision 0017).
final class PageEditor: NSObject {
    let book: AppOpenBook
    let focus: PageFocus
    private(set) weak var textView: ManuscriptTextView?
    private(set) var scene: SceneID?
    /// The body the storage holds, as the model had it after the last edit or load.
    private var shown: [Paragraph] = []
    private var isLoading = false
    /// The page holds edits the model hasn't seen, because an input method was composing.
    private var isBehindComposition = false
    /// The model won a clash with an edit on the page; the page reloads from it next turn.
    private var isAwaitingReload = false
    /// An edit put text on the page that the character policy doesn't admit.
    private var holdsUnadmittedText = false
    /// Comments a paste is adding, handed to the model with the text that carries them.
    private var pastedComments: [Comment] = []

    /// Our own type first; then rich text, so pasted bold and italic survive; then plain.
    static let readableTypes: [NSPasteboard.PasteboardType] = [.pageClip, .rtf, .rtfd, .html, .string]

    init(book: AppOpenBook, focus: PageFocus) {
        self.book = book
        self.focus = focus
    }

    func attach(_ view: ManuscriptTextView) {
        textView = view
        view.editor = self
        view.delegate = self
        view.textStorage?.delegate = self
        focus.body = view
    }

    /// Shows `scene` as the model now has it; editable only when `editability` says so.
    func show(_ scene: SceneID, _ editability: Editability) {
        guard let view = textView else { return }
        let body = book.book.scene(scene)?.body ?? []
        if scene != self.scene {
            load(scene, body, caret: 0)
            view.scroll(.zero)
        } else if body != shown {
            load(scene, body, caret: view.selectedRange().location)
        }
        let editable = editability == .editable
        if view.isEditable != editable {
            view.isEditable = editable
            if !editable, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        }
    }

    enum Editability {
        case editable, readOnly
    }

    private func load(_ scene: SceneID, _ body: [Paragraph], caret: Int) {
        guard let view = textView, let storage = view.textStorage else { return }
        view.breakUndoCoalescing()
        self.scene = scene
        isLoading = true
        storage.setAttributedString(RunCodec.attributedString(forBody: body))
        isLoading = false
        isBehindComposition = false
        isAwaitingReload = false
        holdsUnadmittedText = false
        shown = body
        view.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        view.typingAttributes = ParagraphRole.body.typingAttributes
    }

    // MARK: Model sync

    private func sync(edited: NSRange, in storage: NSTextStorage) {
        guard let scene, let view = textView, !isAwaitingReload, let model = book.book.scene(scene)?.body
        else { return }
        // An input method's uncommitted text isn't the writer's yet: the model, and so
        // autosave, never sees it. The page is converted whole once the composition ends.
        if view.hasMarkedText() {
            isBehindComposition = true
            return
        }
        if isBehindComposition {
            // Caught up by `compositionMayHaveEnded`, outside the storage's editing, where the
            // page can be reloaded at once if it must be.
            DispatchQueue.main.async { [weak self] in self?.compositionMayHaveEnded() }
            return
        }
        guard
            let edit = RunCodec.bodyChange(
                edited: edited, in: storage, linesBefore: BodyChange.lineCount(of: shown))
        else {
            push(RunCodec.bodyChange(replacingAll: BodyChange.lineCount(of: model), with: storage), to: scene)
            return
        }
        if model == shown {
            push(edit, to: scene)
        } else if Self.canMerge(edit, from: shown, into: model) {
            // Something else changed the model in this same turn, in other paragraphs: both
            // changes are kept, and the page shows the other one from the next turn.
            let page = edit.applied(to: shown) ?? shown
            push(edit, to: scene)
            shown = page
            reloadNextTurn(scene)
        } else {
            // Both changed the same paragraphs, or the other change added or removed some:
            // the model, the source of truth, wins, and the page reloads from it. Only a change
            // to the model made within the very turn of a keystroke gets here; otherwise
            // SwiftUI reloads the page in between.
            isAwaitingReload = true
            reloadNextTurn(scene)
        }
    }

    /// Hands `change` to the model, with the comments a paste brings.
    private func push(_ change: BodyChange, to scene: SceneID) {
        let comments = pastedComments
        pastedComments = []
        guard let accepted = book.apply(change, to: scene, adding: comments) else { return }
        shown = book.book.scene(scene)?.body ?? []
        if accepted != change.paragraphs {
            // The model dropped comment ids it has no comment for; the page must too.
            reloadNextTurn(scene)
        }
    }

    /// Whether `edit`, made by the writer to `base`, can be applied as it is to `model`,
    /// which something else changed: it can when the other change left the edited
    /// paragraphs alone and added or removed none.
    private static func canMerge(_ edit: BodyChange, from base: [Paragraph], into model: [Paragraph]) -> Bool
    {
        guard BodyChange.lineCount(of: base) == BodyChange.lineCount(of: model),
            let before = edit.replaced(in: base), let now = edit.replaced(in: model)
        else { return false }
        return before == now
    }

    /// Called when the input method may have committed or abandoned its marked text.
    func compositionMayHaveEnded() {
        guard isBehindComposition, let scene, let view = textView, !view.hasMarkedText(),
            let storage = view.textStorage, !storage.editedMask.contains(.editedCharacters),
            let model = book.book.scene(scene)?.body
        else { return }
        isBehindComposition = false
        push(RunCodec.bodyChange(replacingAll: BodyChange.lineCount(of: model), with: storage), to: scene)
        // Text an input method left behind without committing it through `insertText`
        // skipped the character policy; the page shows what the model admitted instead.
        if !(storage.string as NSString).isEqual(to: RunCodec.attributedString(forBody: shown).string) {
            load(scene, shown, caret: view.selectedRange().location)
        }
    }

    /// The model has the policy's reading of such text; the page shows that instead. The undo
    /// history describes the text that was there, so it's cleared, after the undo or redo that
    /// may be running.
    private func reloadIfThePageHoldsUnadmittedText() {
        guard holdsUnadmittedText, let scene, let view = textView, !view.hasMarkedText(),
            view.textStorage?.editedMask.isEmpty ?? false
        else { return }
        holdsUnadmittedText = false
        load(scene, book.book.scene(scene)?.body ?? [], caret: view.selectedRange().location)
        let undo = book.pageUndo(for: scene)
        DispatchQueue.main.async { undo.removeAllActions() }
    }

    private func reloadNextTurn(_ scene: SceneID) {
        DispatchQueue.main.async { [weak self] in self?.reload(scene) }
    }

    private func reload(_ scene: SceneID) {
        guard scene == self.scene, let view = textView else { return }
        load(scene, book.book.scene(scene)?.body ?? [], caret: view.selectedRange().location)
    }

    // MARK: Pasteboard (decision 0017)

    /// The app's pasteboard data for the text in `ranges`, joined by line breaks.
    func clipData(of ranges: [NSRange]) -> Data? {
        guard let scene = scene.flatMap(book.book.scene), let storage = textView?.textStorage else {
            return nil
        }
        let text = NSMutableAttributedString()
        for (index, range) in ranges.enumerated() where range.length > 0 {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(storage.attributedSubstring(from: range))
        }
        let lines = RunCodec.body(from: text)
        return lines.isEmpty ? nil : PageClip(lines, from: scene).data
    }

    func paste(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let scene, let view = textView, view.isEditable else { return false }
        if type == .pageClip {
            guard let data = pasteboard.data(forType: type), let clip = PageClip(data: data),
                let pasted = book.resolve(clip, into: scene), !pasted.lines.isEmpty
            else {
                // A clip with nothing to paste: use the text the same copy put beside it.
                let fallback = pasteboard.availableType(from: Array(Self.readableTypes.dropFirst()))
                return fallback.map { paste(from: pasteboard, type: $0) } ?? false
            }
            insert(pasted.lines, adding: pasted.comments)
            return true
        }
        guard let text = Self.foreignText(on: pasteboard, type: type, typing: view.typingAttributes) else {
            return false
        }
        let lines = RunCodec.body(from: text).map { paragraph in
            Paragraph(
                paragraph.runs.map { run in
                    var run = run
                    run.comments = []
                    return run
                })
        }
        guard !lines.isEmpty else { return false }
        insert(lines, adding: [])
        return true
    }

    /// Text another app put on the pasteboard; plain text takes the typing attributes.
    private static func foreignText(
        on pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType, typing: [NSAttributedString.Key: Any]
    ) -> NSAttributedString? {
        if type == .string {
            return pasteboard.string(forType: .string).map {
                NSAttributedString(string: $0, attributes: typing)
            }
        }
        guard let data = pasteboard.data(forType: type) else { return nil }
        switch type {
        case .rtf: return NSAttributedString(rtf: data, documentAttributes: nil)
        case .rtfd: return NSAttributedString(rtfd: data, documentAttributes: nil)
        case .html: return NSAttributedString(html: data, documentAttributes: nil)
        default: return nil
        }
    }

    /// Replaces the selection with `lines` as one undoable change that adds `comments` to the
    /// scene with the text.
    private func insert(_ lines: [Paragraph], adding comments: [Comment]) {
        guard let scene, let view = textView, let storage = view.textStorage, let undo = view.undoManager,
            !lines.isEmpty
        else { return }
        let range = view.rangeForUserTextChange
        guard range.location != NSNotFound else { return }
        let text = RunCodec.attributedString(forBody: lines)
        view.breakUndoCoalescing()
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        if !comments.isEmpty {
            // Registered before the text, so undoing the paste takes the text away first and no
            // run is ever left naming a comment the scene doesn't have.
            let ids = Set(comments.map(\.id))
            undo.registerUndo(withTarget: book) { $0.removeComments(ids, from: scene) }
        }
        guard view.shouldChangeText(in: range, replacementString: text.string) else { return }
        pastedComments = comments
        storage.replaceCharacters(in: range, with: text)
        pastedComments = []
        view.didChangeText()
        view.setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
    }
}

extension PageEditor: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? {
        scene.map(book.pageUndo(for:))
    }

    /// Every typed or replaced string goes through the character policy (ADR 0022). When the
    /// policy changes it, this change is refused and the admitted text put in its place.
    func textView(
        _ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
        replacementStrings: [String]?
    ) -> Bool {
        guard let strings = replacementStrings, let view = textView as? ManuscriptTextView, !view.isComposing
        else { return true }
        let admitted = strings.map(CharacterPolicy.admittedInput)
        // Code units, not `String ==`, which calls `e` + U+0301 and `é` equal.
        guard zip(admitted, strings).contains(where: { !$0.utf16.elementsEqual($1.utf16) }) else {
            return true
        }
        view.replace(affectedRanges.map(\.rangeValue), with: admitted)
        return false
    }

    func textDidChange(_ notification: Notification) {
        compositionMayHaveEnded()
        reloadIfThePageHoldsUnadmittedText()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        compositionMayHaveEnded()
        guard let view = textView, !view.hasMarkedText() else { return }
        view.typingAttributes = ParagraphRole.body.typingAttributes(continuing: view.typingAttributes)
    }
}

extension PageEditor: @MainActor NSTextStorageDelegate {
    /// A paragraph break has no format the model could store, so on the page it always has the
    /// body role's, as the codec renders it; otherwise a break typed in bold would be bold on
    /// the page alone.
    func textStorage(
        _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard !isLoading else { return }
        let string = textStorage.string as NSString
        let plain = ParagraphRole.body.typingAttributes
        let breaks = Set<unichar>([0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029])
        for index in editedRange.location..<editedRange.upperBound
        where breaks.contains(string.character(at: index)) {
            let attributes = textStorage.attributes(at: index, effectiveRange: nil)
            if !NSDictionary(dictionary: attributes).isEqual(to: plain) {
                textStorage.setAttributes(plain, range: NSRange(location: index, length: 1))
            }
        }
    }

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isLoading else { return }
        if let view = textView, !view.hasMarkedText(), Self.holdsUnadmittedText(textStorage, in: editedRange)
        {
            holdsUnadmittedText = true
            DispatchQueue.main.async { [weak self] in self?.reloadIfThePageHoldsUnadmittedText() }
        }
        sync(edited: editedRange, in: textStorage)
    }

    /// Whether `range` holds a character the policy doesn't admit. Only an edit that bypasses
    /// the veto puts one there: undoing or redoing an input method's marked text does.
    private static func holdsUnadmittedText(_ storage: NSTextStorage, in range: NSRange) -> Bool {
        let string = storage.string as NSString
        return (range.location..<range.upperBound).contains { index in
            let unit = string.character(at: index)
            return unit != 0x0A && !(Unicode.Scalar(unit).map(CharacterPolicy.isAllowed) ?? false)
        }
    }
}
