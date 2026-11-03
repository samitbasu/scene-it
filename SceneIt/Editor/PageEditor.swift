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
        shown = body
        view.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        view.typingAttributes = ParagraphRole.body.typingAttributes
    }

    // MARK: Model sync

    private func sync(edited: NSRange, in storage: NSTextStorage) {
        guard let scene, let model = book.book.scene(scene)?.body else { return }
        let lines = BodyChange.lineCount(of: model)
        // The model only changes from elsewhere between turns, so this is a backstop: the
        // whole page is then converted, and the page wins.
        let change =
            model == shown
            ? RunCodec.bodyChange(edited: edited, in: storage, linesBefore: lines)
            : nil
        let comments = pastedComments
        pastedComments = []
        guard
            let accepted = book.apply(
                change ?? RunCodec.bodyChange(replacingAll: lines, with: storage), to: scene, adding: comments
            )
        else { return }
        shown = book.book.scene(scene)?.body ?? []
        if let change, accepted != change.paragraphs {
            // The model dropped comment ids it has no comment for; the page must too.
            DispatchQueue.main.async { [weak self] in self?.reload(scene) }
        }
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
                let pasted = book.resolve(clip, into: scene)
            else { return false }
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
        guard admitted != strings else { return true }
        view.replace(affectedRanges.map(\.rangeValue), with: admitted)
        return false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = textView, !view.hasMarkedText() else { return }
        view.typingAttributes = ParagraphRole.body.typingAttributes(continuing: view.typingAttributes)
    }
}

extension PageEditor: @MainActor NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isLoading else { return }
        sync(edited: editedRange, in: textStorage)
    }
}
