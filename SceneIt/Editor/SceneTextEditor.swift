import AppKit
import SceneItCore
import SwiftUI

/// Keeps a text view's storage a mirror of one part of the open scene, its body (the page) or
/// its notes (the Notes tab), which is the one source of truth: the storage is rebuilt from
/// the model when the scene (or the part, from elsewhere) changes, and every edit to the
/// storage reaches the model in the same main-actor turn, as the paragraphs it touched
/// (`BodyChange`), so autosave hears of it at once.
///
/// It's the gate for what the writer types and pastes: the character policy (ADR 0028), the
/// codec's rules for pasted text (decision 0016), comments that never spread by typing
/// (PLAN §8.1), and the app's own pasteboard type (decision 0017). The page and the notes
/// each have one, so they can't differ in any of these.
final class SceneTextEditor: NSObject {
    let book: AppOpenBook
    let part: TextPart
    let formatting: EditorFormatting
    /// The window's selected comment, which a click on commented text changes.
    let comments: CommentSelection
    private(set) weak var textView: SceneTextView?
    private(set) var scene: SceneID?
    /// The part the storage holds, as the model had it after the last edit or load.
    private var shown: [Paragraph] = []
    private var isLoading = false
    private var sync = Sync.inStep
    /// Comments a paste is adding, handed to the model with the text that carries them.
    private var pastedComments: [Comment] = []

    /// Our own type first; then rich text, so pasted bold and italic survive; then plain.
    static let readableTypes: [NSPasteboard.PasteboardType] = [.pageClip, .rtf, .rtfd, .html, .string]

    init(book: AppOpenBook, part: TextPart, formatting: EditorFormatting, comments: CommentSelection) {
        self.book = book
        self.part = part
        self.formatting = formatting
        self.comments = comments
    }

    /// The writer clicked the character at `index`, or its underlines: if comments cover it,
    /// the newest is selected, or the next of them when one is already (PLAN §8.1).
    func clickedComments(at index: Int) {
        guard let scene, let view = textView, let storage = view.textStorage else { return }
        comments.click(covering: view.commentPalette.newestFirst(at: index, in: storage), in: scene)
    }

    private var role: ParagraphRole {
        part.role
    }

    /// The part of `scene` as the model has it.
    private func modelText(of scene: SceneID) -> [Paragraph]? {
        book.book.scene(scene)?[keyPath: part.paragraphs]
    }

    func attach(_ view: SceneTextView) {
        textView = view
        view.editor = self
        view.delegate = self
        view.textStorage?.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillSwitch), name: .openBookWillSwitchScene, object: book)
    }

    /// Before another scene opens: what's being typed stays in this one.
    @objc private func sceneWillSwitch(_ notification: Notification) {
        textView?.breakUndoCoalescing()
    }

    /// Shows `scene` as the model now has it; editable only when `editability` says so.
    func show(_ scene: SceneID, _ editability: Editability) {
        guard let view = textView else { return }
        let comments = book.book.scene(scene)?.comments ?? []
        view.commentPalette = CommentPalette(comments)
        self.comments.forget(allBut: Set(comments.map(\.id)), in: scene)
        let text = modelText(of: scene) ?? []
        if scene != self.scene {
            load(scene, text, caret: 0)
            view.scroll(.zero)
        } else if text != shown {
            load(scene, text, caret: view.selectedRange().location)
        }
        let editable = editability == .editable
        if view.isEditable != editable {
            view.isEditable = editable
            if !editable, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
            showFormatting()
        }
    }

    enum Editability {
        case editable, readOnly

        /// Editable in an editable book, unless SwiftUI disabled the view, as under a sheet.
        init(_ book: AppOpenBook, in environment: EnvironmentValues) {
            self = book.isEditable && environment.isEnabled ? .editable : .readOnly
        }
    }

    /// How the text view stands with the model.
    private enum Sync {
        /// Every edit in the view has reached the model.
        case inStep
        /// The model changed under the view; the editor ignores its edits until it reloads.
        case awaitingReload
    }

    private func load(_ scene: SceneID, _ text: [Paragraph], caret: Int) {
        guard let view = textView, let storage = view.textStorage else { return }
        view.breakUndoCoalescing()
        self.scene = scene
        isLoading = true
        storage.setAttributedString(RunCodec.attributedString(text, in: part))
        isLoading = false
        sync = .inStep
        shown = text
        view.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        view.typingAttributes = role.typingAttributes
        showFormatting()
    }

    // MARK: Model sync

    private func edited(_ range: NSRange, in storage: NSTextStorage) {
        guard let scene, sync != .awaitingReload else { return }
        guard let model = modelText(of: scene), model == shown else {
            // A backstop that SwiftUI's update ordering should make unreachable: it reloads the
            // view whenever the model changes, before the next event. If the model changed
            // under the view within this turn anyway, the model, the source of truth, wins.
            Log.editor.error(
                "the open scene's text changed under its editor; reloading the editor from the model",
                ["part": .symbol(part.logName), "paragraphs": .count(shown.count)])
            sync = .awaitingReload
            DispatchQueue.main.async { [weak self] in self?.reload(scene, clearingUndo: .yes) }
            return
        }
        let change =
            RunCodec.bodyChange(edited: range, in: storage, linesBefore: BodyChange.lineCount(of: shown))
            ?? RunCodec.bodyChange(replacingAll: BodyChange.lineCount(of: model), with: storage)
        push(change, to: scene)
        if Self.holdsUnadmittedText(storage, in: range) {
            // A backstop: only an edit that skipped the veto puts such a character in the view.
            // The model took the admitted reading; the view shows it once the edit is over.
            Log.editor.error(
                "an edit bypassed the character policy; reloading the editor from the model",
                ["part": .symbol(part.logName), "characters": .count(range.length)])
            DispatchQueue.main.async { [weak self] in self?.reload(scene, clearingUndo: .yes) }
        }
    }

    /// Whether `range` holds a character the policy doesn't admit.
    private static func holdsUnadmittedText(_ storage: NSTextStorage, in range: NSRange) -> Bool {
        let string = storage.string as NSString
        return (range.location..<range.upperBound).contains { index in
            !(Unicode.Scalar(string.character(at: index)).map(CharacterPolicy.isAdmitted) ?? false)
        }
    }

    /// Hands `change` to the model, with the comments a paste brings.
    private func push(_ change: BodyChange, to scene: SceneID) {
        let comments = pastedComments
        pastedComments = []
        guard let accepted = book.apply(change, to: scene, in: part, adding: comments) else { return }
        shown = modelText(of: scene) ?? []
        if accepted != change.paragraphs {
            // The model dropped comment ids it has no comment for; the view must too.
            DispatchQueue.main.async { [weak self] in self?.reload(scene, clearingUndo: .no) }
        }
    }

    enum UndoClearing {
        /// The editor's undo history describes text that's gone.
        case yes
        case no
    }

    /// Shows the model's text of `scene` again, if it's still the editor's scene.
    private func reload(_ scene: SceneID, clearingUndo clearing: UndoClearing) {
        guard scene == self.scene, let view = textView else { return }
        load(scene, modelText(of: scene) ?? [], caret: view.selectedRange().location)
        if clearing == .yes {
            // After any undo or redo that's running: it may be what brought the text in.
            let undo = book.undo(for: scene, part)
            DispatchQueue.main.async { undo.removeAllActions() }
        }
    }

    // MARK: Formatting (PLAN §6.2)

    /// Applies `command` to the selection as one undoable change, through the text view so the
    /// model hears of it as of any edit; with nothing selected, to what the writer types next.
    /// Returns whether it applied.
    func format(_ command: FormattingCommand) -> Bool {
        guard let view = textView, let storage = view.textStorage, let selection = formattingSelection
        else { return false }
        let edit = command.edit(for: selection)
        let ranges = view.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        if ranges.isEmpty {
            view.typingAttributes = role.typingAttributes(
                continuing: edit.applied(to: view.typingAttributes, in: role))
            showFormatting()
            return true
        }
        view.breakUndoCoalescing()
        guard view.shouldChangeText(inRanges: ranges.map(NSValue.init(range:)), replacementStrings: nil)
        else { return false }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        for range in ranges {
            storage.enumerateAttributes(in: range) { attributes, run, _ in
                runs.append((run, edit.applied(to: attributes, in: role)))
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

    /// The selection's formats, while the text can be formatted.
    private var formattingSelection: SelectionFormatting? {
        guard let view = textView, let storage = view.textStorage, view.keyboardFocus == .here,
            view.isEditable
        else { return nil }
        let ranges = view.selectedRanges.map(\.rangeValue)
        return ranges.contains(where: { $0.length > 0 })
            ? SelectionFormatting(selecting: ranges, in: storage)
            : SelectionFormatting(typing: view.typingAttributes)
    }

    /// Shows the formats of the selection, or none while the text view can't be formatted.
    func showFormatting() {
        formatting.show(formattingSelection, from: self)
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
        let lines = RunCodec.paragraphs(from: text)
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
        let lines = RunCodec.paragraphs(from: text).map { paragraph in
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
        let text = RunCodec.attributedString(lines, in: part)
        view.breakUndoCoalescing()
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        if !comments.isEmpty {
            // Registered before the text, so undoing the paste takes the text away first and no
            // run is ever left naming a comment the scene doesn't have.
            let ids = Set(comments.map(\.id))
            undo.registerUndo(withTarget: book) { [part] in
                $0.removeComments(ids, from: scene, pastedInto: part)
            }
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

extension SceneTextEditor: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? {
        scene.map { book.undo(for: $0, part) }
    }

    /// Every typed or replaced string goes through the character policy (ADR 0028). When the
    /// policy changes it, this change is refused and the admitted text put in its place.
    func textView(
        _ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
        replacementStrings: [String]?
    ) -> Bool {
        guard let strings = replacementStrings, let view = textView as? SceneTextView else {
            return true
        }
        guard let admitted = KeyboardTextView.corrected(strings, by: CharacterPolicy.admittedInput) else {
            return true
        }
        view.replace(affectedRanges.map(\.rangeValue), with: admitted)
        return false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = textView else { return }
        view.typingAttributes = role.typingAttributes(continuing: view.typingAttributes)
        showFormatting()
    }
}

extension SceneTextEditor: @MainActor NSTextStorageDelegate {
    /// A paragraph break has no format the model could store, so in the view it always has the
    /// role's own, as the codec renders it; otherwise a break typed in bold would be bold in
    /// the view alone.
    func textStorage(
        _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard !isLoading else { return }
        let string = textStorage.string as NSString
        let plain = role.typingAttributes
        for index in editedRange.location..<editedRange.upperBound where string.isLineBreak(at: index) {
            let attributes = textStorage.attributes(at: index, effectiveRange: nil)
            // Its paragraph style is `styleParagraphs`'s, below.
            var expected = plain
            expected[.paragraphStyle] = attributes[.paragraphStyle]
            if !NSDictionary(dictionary: attributes).isEqual(to: expected) {
                textStorage.setAttributes(expected, range: NSRange(location: index, length: 1))
            }
        }
        // The paragraph after the edit too: a break inserted before its text can leave it empty.
        let rest = string.length - editedRange.location
        let following = NSRange(location: editedRange.location, length: min(editedRange.length + 1, rest))
        role.styleParagraphs(of: textStorage, around: following)
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
}

extension TextPart {
    fileprivate var logName: StaticString {
        switch self {
        case .body: "body"
        case .notes: "notes"
        }
    }
}
