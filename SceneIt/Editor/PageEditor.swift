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
    let formatting: PageFormatting
    private(set) weak var textView: ManuscriptTextView?
    private(set) var scene: SceneID?
    /// The body the storage holds, as the model had it after the last edit or load.
    private var shown: [Paragraph] = []
    private var isLoading = false
    private var sync = Sync.inStep
    /// Comments a paste is adding, handed to the model with the text that carries them.
    private var pastedComments: [Comment] = []
    private var keyboardFocus = KeyboardFocus.elsewhere

    /// Our own type first; then rich text, so pasted bold and italic survive; then plain.
    static let readableTypes: [NSPasteboard.PasteboardType] = [.pageClip, .rtf, .rtfd, .html, .string]

    init(book: AppOpenBook, focus: PageFocus, formatting: PageFormatting) {
        self.book = book
        self.focus = focus
        self.formatting = formatting
    }

    func attach(_ view: ManuscriptTextView) {
        textView = view
        view.editor = self
        view.delegate = self
        view.textStorage?.delegate = self
        focus.body = view
        formatting.editor = self
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
            if !editable { commitComposition() }
            view.isEditable = editable
            if !editable, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
            showFormatting()
        }
    }

    enum Editability {
        case editable, readOnly
    }

    enum KeyboardFocus {
        case page, elsewhere
    }

    /// How the page stands with the model.
    private enum Sync {
        /// Every edit on the page has reached the model.
        case inStep
        /// An input method is composing, or has just finished: the model hasn't seen the page
        /// since, and gets all of it when the composition ends.
        case behindComposition
        /// An edit bypassed the character policy's veto; the model holds the admitted reading,
        /// and the page reloads from it once the edit is over.
        case holdingUnadmittedText
        /// The model changed under the page; the page ignores its own edits until it reloads.
        case awaitingReload
    }

    private func load(_ scene: SceneID, _ body: [Paragraph], caret: Int) {
        guard let view = textView, let storage = view.textStorage else { return }
        commitComposition()
        view.breakUndoCoalescing()
        self.scene = scene
        isLoading = true
        storage.setAttributedString(RunCodec.attributedString(forBody: body))
        isLoading = false
        sync = .inStep
        shown = body
        view.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        view.typingAttributes = ParagraphRole.body.typingAttributes
        showFormatting()
    }

    /// Ends an input method's composition before anything replaces the page's text: a marked
    /// range left behind would later replace characters of whatever the page shows next. The
    /// composition is kept, in the scene it was typed in, unless the model changed under the
    /// page; then the model wins and the composition is dropped.
    private func commitComposition() {
        guard let view = textView, view.hasMarkedText() else { return }
        if scene.flatMap({ book.book.scene($0)?.body }) != shown { sync = .awaitingReload }
        view.unmarkText()
        view.inputContext?.discardMarkedText()
    }

    // MARK: Model sync

    private func edited(_ range: NSRange, in storage: NSTextStorage) {
        guard let scene, let view = textView, sync != .awaitingReload else { return }
        // An input method's uncommitted text isn't the writer's yet: the model, and so
        // autosave, never sees it. The page is converted whole once the composition ends.
        if view.hasMarkedText() {
            sync = .behindComposition
            return
        }
        if sync == .behindComposition {
            // Caught up by `compositionMayHaveEnded`, outside the storage's editing, where the
            // page can be reloaded at once if it must be.
            DispatchQueue.main.async { [weak self] in self?.compositionMayHaveEnded() }
            return
        }
        if Self.holdsUnadmittedText(storage, in: range) {
            sync = .holdingUnadmittedText
            DispatchQueue.main.async { [weak self] in self?.reloadIfThePageHoldsUnadmittedText() }
        }
        guard let model = book.book.scene(scene)?.body, model == shown else {
            // A backstop that SwiftUI's update ordering should make unreachable: it reloads the
            // page whenever the model changes, before the next event. If the model changed
            // under the page within this turn anyway, the model, the source of truth, wins.
            Log.editor.error(
                "the open scene's body changed under the page; reloading the page from the model",
                ["paragraphs": .count(shown.count)])
            sync = .awaitingReload
            DispatchQueue.main.async { [weak self] in self?.reload(scene, clearingUndo: .yes) }
            return
        }
        let change =
            RunCodec.bodyChange(edited: range, in: storage, linesBefore: BodyChange.lineCount(of: shown))
            ?? RunCodec.bodyChange(replacingAll: BodyChange.lineCount(of: model), with: storage)
        push(change, to: scene)
    }

    /// Hands `change` to the model, with the comments a paste brings.
    private func push(_ change: BodyChange, to scene: SceneID) {
        let comments = pastedComments
        pastedComments = []
        guard let accepted = book.apply(change, to: scene, adding: comments) else { return }
        shown = book.book.scene(scene)?.body ?? []
        if accepted != change.paragraphs {
            // The model dropped comment ids it has no comment for; the page must too.
            DispatchQueue.main.async { [weak self] in self?.reload(scene, clearingUndo: .no) }
        }
    }

    /// Called when the input method may have committed or abandoned its marked text.
    func compositionMayHaveEnded() {
        guard sync == .behindComposition, let scene, let view = textView, !view.hasMarkedText(),
            let storage = view.textStorage, !storage.editedMask.contains(.editedCharacters),
            let model = book.book.scene(scene)?.body
        else { return }
        sync = .inStep
        push(RunCodec.bodyChange(replacingAll: BodyChange.lineCount(of: model), with: storage), to: scene)
        // Text an input method left behind without committing it through `insertText`
        // skipped the character policy; the page shows what the model admitted instead.
        if !(storage.string as NSString).isEqual(to: RunCodec.attributedString(forBody: shown).string) {
            reload(scene, clearingUndo: .yes)
        }
    }

    private func reloadIfThePageHoldsUnadmittedText() {
        guard sync == .holdingUnadmittedText, let scene, let view = textView, !view.hasMarkedText(),
            view.textStorage?.editedMask.isEmpty ?? false
        else { return }
        reload(scene, clearingUndo: .yes)
    }

    enum UndoClearing {
        /// The page's undo history describes text that's gone.
        case yes
        case no
    }

    /// Shows the model's body of `scene` again, if it's still the page's scene.
    private func reload(_ scene: SceneID, clearingUndo clearing: UndoClearing) {
        guard scene == self.scene, let view = textView else { return }
        load(scene, book.book.scene(scene)?.body ?? [], caret: view.selectedRange().location)
        if clearing == .yes {
            // After any undo or redo that's running: it may be what brought the text in.
            let undo = book.pageUndo(for: scene)
            DispatchQueue.main.async { undo.removeAllActions() }
        }
    }

    // MARK: Formatting (PLAN §6.2)

    func keyboardFocusChanged(_ focus: KeyboardFocus) {
        keyboardFocus = focus
        showFormatting()
    }

    /// Applies `command` to the selection as one undoable change, through the text view so the
    /// model hears of it as of any edit; with nothing selected, to what the writer types next.
    /// Returns whether it applied.
    func format(_ command: FormattingCommand) -> Bool {
        guard let view = textView, let storage = view.textStorage, let selection = formattingSelection
        else { return false }
        let edit = command.edit(for: selection)
        let ranges = view.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        if ranges.isEmpty {
            view.typingAttributes = ParagraphRole.body.typingAttributes(
                continuing: edit.applied(to: view.typingAttributes, in: .body))
            showFormatting()
            return true
        }
        view.breakUndoCoalescing()
        guard view.shouldChangeText(inRanges: ranges.map(NSValue.init(range:)), replacementStrings: nil)
        else { return false }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        for range in ranges {
            storage.enumerateAttributes(in: range) { attributes, run, _ in
                runs.append((run, edit.applied(to: attributes, in: .body)))
            }
        }
        storage.beginEditing()
        for (range, attributes) in runs { storage.setAttributes(attributes, range: range) }
        storage.endEditing()
        view.didChangeText()
        view.undoManager?.setActionName(WindowWording.undoName(command))
        showFormatting()
        return true
    }

    /// The selection's formats, while the page can be formatted.
    private var formattingSelection: SelectionFormatting? {
        guard let view = textView, let storage = view.textStorage, keyboardFocus == .page, view.isEditable
        else { return nil }
        let ranges = view.selectedRanges.map(\.rangeValue)
        return ranges.contains(where: { $0.length > 0 })
            ? SelectionFormatting(selecting: ranges, in: storage)
            : SelectionFormatting(typing: view.typingAttributes)
    }

    private func showFormatting() {
        formatting.show(formattingSelection)
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
                let fallback = pasteboard.availableType(from: Self.readableTypes.filter { $0 != .pageClip })
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
        showFormatting()
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
        for index in editedRange.location..<editedRange.upperBound
        where Self.isLineBreak(string.character(at: index)) {
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
        edited(editedRange, in: textStorage)
        // An undo or redo of formatting changes the selection's format without moving it, and
        // without `textDidChange`. (After a change of characters the selection still has its
        // old ranges here, and moves later, which shows the formatting then.)
        if !editedMask.contains(.editedCharacters) { showFormatting() }
    }

    /// A UTF-16 unit that is a line break by the codec's rule; a surrogate never is.
    private static func isLineBreak(_ unit: unichar) -> Bool {
        Unicode.Scalar(unit).map { Character($0).isLineBreak } ?? false
    }

    /// Whether `range` holds a character the policy doesn't admit. Only an edit that bypasses
    /// the veto puts one there: undoing or redoing an input method's marked text does.
    private static func holdsUnadmittedText(_ storage: NSTextStorage, in range: NSRange) -> Bool {
        let string = storage.string as NSString
        return (range.location..<range.upperBound).contains { index in
            !(Unicode.Scalar(string.character(at: index)).map(CharacterPolicy.isAdmitted) ?? false)
        }
    }
}
