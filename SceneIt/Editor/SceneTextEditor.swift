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
    /// Where a new comment's color comes from, and a chosen one goes (PLAN §8.1).
    let preferences: AppPreferences
    let formatting: EditorFormatting
    /// The window's selected comment, which a click on commented text changes.
    let comments: CommentSelection
    private(set) weak var textView: SceneTextView?
    private(set) var scene: SceneID?
    /// The part the storage holds, as the model had it after the last edit or load.
    private var shown: [Paragraph] = []
    private var storageEdit = StorageEdit.byTheView
    /// The paragraphs edits touched since they were last restyled.
    private var paragraphsToRestyle: NSRange?
    private var sync = Sync.inStep
    /// Comments the edit under way adds (a paste's, or a new one), handed to the model with the
    /// text that carries them.
    private var addedComments: [Comment] = []
    private var pendingReveal = PendingSelection()

    /// Our own type first; then rich text, so pasted bold and italic survive; then plain.
    static let readableTypes: [NSPasteboard.PasteboardType] = [.pageClip, .rtf, .rtfd, .html, .string]

    init(
        book: AppOpenBook, part: TextPart, preferences: AppPreferences, formatting: EditorFormatting,
        comments: CommentSelection
    ) {
        self.book = book
        self.part = part
        self.preferences = preferences
        self.formatting = formatting
        self.comments = comments
    }

    /// The writer clicked the character at `index`, or its underlines: if comments cover it,
    /// the newest is selected, or the next of them when one is already (PLAN §8.1).
    func clickedComments(at index: Int) {
        guard let scene, let page = textView as? ManuscriptTextView, let storage = page.textStorage else {
            return
        }
        comments.click(covering: page.commentPalette.newestFirst(at: index, in: storage), in: scene)
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

    /// The view's undo and redo of typing change the storage without its `didChangeText`.
    @objc private func undoManagerDidUndoOrRedo(_ notification: Notification) {
        restyleEditedParagraphs()
    }

    /// Its scene's undo, and only its.
    private let heardUndo = HeardUndo()

    /// Shows `scene` as the model now has it; editable only when `editability` says so.
    func show(_ scene: SceneID, _ editability: Editability) {
        guard let view = textView else { return }
        if view is ManuscriptTextView {
            let comments = showComments(of: scene)
            self.comments.forget(allBut: Set(comments.map(\.id)), in: scene)
        }
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
        if let range = pendingReveal.take(showing: scene) {
            select(range, in: view)
        }
    }

    /// Underlines `scene`'s comments on the page as the model has them; returns them.
    @discardableResult
    private func showComments(of scene: SceneID) -> [Comment] {
        let comments = book.book.scene(scene)?.comments ?? []
        (textView as? ManuscriptTextView)?.commentPalette = CommentPalette(comments)
        return comments
    }

    /// Selects `range` of `scene`'s text, scrolled into view and with the focus, when the view
    /// next shows `scene`: a search result being opened (PLAN §9.1).
    func reveal(_ range: NSRange, in scene: SceneID) {
        pendingReveal.set(range, in: scene)
    }

    private func select(_ range: NSRange, in view: SceneTextView) {
        let selection = range.clamped(toLength: view.textStorage?.length ?? 0)
        view.setSelectedRange(selection)
        view.scrollRangeToVisible(selection)
        // The sheet's focus holder leaves the window in this same update.
        DispatchQueue.main.async { [weak view] in
            view?.takeFocus()
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
        heardUndo.hear(book.undo(for: scene, part), by: self, calling: #selector(undoManagerDidUndoOrRedo))
        paragraphsToRestyle = nil
        do {
            let previous = storageEdit
            storageEdit = .loading
            defer { storageEdit = previous }
            storage.setAttributedString(RunCodec.attributedString(text, in: part))
        }
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

    /// Hands `change` to the model, with the comments the edit adds.
    private func push(_ change: BodyChange, to scene: SceneID) {
        let comments = addedComments
        addedComments = []
        guard let accepted = book.apply(change, to: scene, in: part, adding: comments) else { return }
        shown = modelText(of: scene) ?? []
        if accepted != change.paragraphs {
            // The model dropped comment ids it has no comment for; the view must too.
            DispatchQueue.main.async { [weak self] in self?.reload(scene, clearingUndo: .no) }
        }
    }

    /// Who is editing the storage, which decides what its delegate does with the edit.
    private enum StorageEdit {
        /// The view, or anyone editing through it or its storage: the model hears of it.
        case byTheView
        /// The editor, showing the model's text, which the codec has already styled.
        case loading
        /// The editor, giving edited paragraphs their style once the edit is over.
        case restyling
    }

    /// Gives the paragraphs the last edits touched the style for what they now hold, as an
    /// attribute-only edit that neither the model nor undo hears of. Never during another edit:
    /// a change of attributes then grows that edit's range, and the view puts the caret at the
    /// end of it.
    func restyleEditedParagraphs() {
        restyleEditedParagraphs(.first)
    }

    /// Whether edited paragraphs are waiting to be restyled.
    var restyleIsPending: Bool {
        paragraphsToRestyle != nil
    }

    private enum RestyleAttempt {
        case first, last
    }

    private func restyleEditedParagraphs(_ attempt: RestyleAttempt) {
        guard storageEdit == .byTheView, let range = paragraphsToRestyle, let storage = textView?.textStorage
        else { return }
        // Inside an open batch of edits the pending range hasn't moved with them yet, either.
        guard storage.editedMask.isEmpty else {
            switch attempt {
            case .first:
                restyleOnTheNextTurn(.last)
            case .last:
                Log.editor.error(
                    "an edit of the storage stayed open; its paragraphs keep their old style",
                    ["part": .symbol(part.logName)])
                paragraphsToRestyle = nil
            }
            return
        }
        paragraphsToRestyle = nil
        storageEdit = .restyling
        defer { storageEdit = .byTheView }
        storage.beginEditing()
        role.styleParagraphs(of: storage, around: range.clamped(toLength: storage.length))
        storage.endEditing()
    }

    /// Adds the paragraphs an edit of `edited` touched, and the one after it (a break
    /// inserted before its text can leave it empty), to those waiting to be restyled, which
    /// move with the edit.
    private func restyleLater(_ edited: NSRange, changeInLength delta: Int, in storage: NSTextStorage) {
        let touched = NSRange(
            location: edited.location, length: min(edited.length + 1, storage.length - edited.location))
        guard let waiting = paragraphsToRestyle else {
            paragraphsToRestyle = touched
            restyleOnTheNextTurn(.first)
            return
        }
        let waitingEnd =
            waiting.upperBound > edited.location
            ? max(edited.upperBound, waiting.upperBound + delta) : waiting.upperBound
        let location = min(waiting.location, touched.location)
        paragraphsToRestyle = NSRange(
            location: location, length: max(waitingEnd, touched.upperBound) - location)
    }

    /// The view's `didChangeText` restyles as an edit ends; this is for an edit that never
    /// reaches it.
    private func restyleOnTheNextTurn(_ attempt: RestyleAttempt) {
        DispatchQueue.main.async { [weak self] in self?.restyleEditedParagraphs(attempt) }
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
        guard let view = textView, let selection = formattingSelection else { return false }
        let edit = command.edit(for: selection)
        let ranges = view.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        if ranges.isEmpty {
            view.typingAttributes = role.typingAttributes(
                continuing: edit.applied(to: view.typingAttributes, in: role))
            showFormatting()
            return true
        }
        guard rewrite(ranges, by: { edit.applied(to: $0, in: role) }) else { return false }
        view.undoManager?.setActionName(WindowWording.undoName(command))
        showFormatting()
        return true
    }

    /// Changes the attributes of `ranges` by `change`, through the text view so the model hears
    /// of it as of any edit, with `comments` added to the scene; one undoable change of the
    /// view's. Returns whether the view took it.
    private func rewrite(
        _ ranges: [NSRange], adding comments: [Comment] = [],
        by change: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]
    ) -> Bool {
        guard let view = textView, let storage = view.textStorage else { return false }
        view.breakUndoCoalescing()
        guard view.shouldChangeText(inRanges: ranges.map(NSValue.init(range:)), replacementStrings: nil)
        else { return false }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        for range in ranges {
            storage.enumerateAttributes(in: range) { attributes, run, _ in
                runs.append((run, change(attributes)))
            }
        }
        addedComments = comments
        storage.beginEditing()
        for (range, attributes) in runs { storage.setAttributes(attributes, range: range) }
        storage.endEditing()
        addedComments = []
        view.didChangeText()
        return true
    }

    // MARK: Comments (PLAN §8.1), on the page only (ADR 0035)

    /// Comments the page's selection with a new comment in
    /// the color last chosen for one, which becomes the selected comment: one change on the
    /// page's undo. Returns the comment; `nil`, changing nothing, in the notes or while the page
    /// can't be edited, and with a beep when there's nothing to comment.
    @discardableResult
    func newComment() -> CommentID? {
        guard let commenting,
            let comment = book.newComment(in: commenting.scene, colored: preferences.lastCommentColor),
            anchor(comment.id, adding: [comment], on: commenting, named: CommentWording.newComment)
        else { return nil }
        return comment.id
    }

    /// Anchors the detached comment `id` to the page's selection (PLAN §8.1), and selects it: one change on the page's undo. Returns whether it
    /// did; never for a comment that still has text on the page, and with a beep when there's
    /// nothing to anchor it to.
    @discardableResult
    func reanchor(_ id: CommentID) -> Bool {
        guard let commenting, let scene = book.book.scene(commenting.scene),
            scene.comments.contains(where: { $0.id == id }), scene.isDetached(id)
        else { return false }
        return anchor(id, adding: [], on: commenting, named: CommentWording.reanchorUndoName)
    }

    /// Puts the comment `id` on the selection and selects it, as one
    /// change named `name` that adds `added` to the scene.
    private func anchor(
        _ id: CommentID, adding added: [Comment], on commenting: Commenting, named name: String
    )
        -> Bool
    {
        let ranges = commenting.storage.commentRanges(
            selecting: commenting.view.selectedRanges.map(\.rangeValue))
        guard !ranges.isEmpty else {
            NSSound.beep()
            return false
        }
        let undo = book.pageUndo(for: commenting.scene)
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        // Registered before the text, so undoing takes the text's id away first and no run is
        // ever left naming a comment the scene doesn't have. If the text refuses the change, the
        // comment never reaches the scene and this removes nothing. Its target is the book, which
        // outlives the history: an undo manager doesn't retain targets.
        if !added.isEmpty {
            undo.registerUndo(withTarget: book) { [scene = commenting.scene] in
                $0.removeComments(Set(added.map(\.id)), from: scene)
            }
        }
        guard rewrite(ranges, adding: added, by: { CommentEdit.add(id).applied(to: $0, in: role) }) else {
            return false
        }
        undo.setActionName(name)
        commenting.view.typingAttributes = role.typingAttributes(continuing: commenting.view.typingAttributes)
        comments.select(id, in: commenting.scene)
        return true
    }

    /// Dismisses the comment `id` (PLAN §8.1): it's taken off its text and out of the scene, as
    /// one change on the page's undo, whose undo restores both. Returns whether it did; if it
    /// didn't, nothing changed.
    @discardableResult
    func dismiss(_ id: CommentID) -> Bool {
        guard let commenting,
            book.book.scene(commenting.scene)?.comments.contains(where: { $0.id == id }) == true
        else { return false }
        commenting.view.breakUndoCoalescing()
        let undo = book.pageUndo(for: commenting.scene)
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        let ranges = commenting.storage.ranges(commentedBy: id)
        guard ranges.isEmpty || rewrite(ranges, by: { CommentEdit.remove(id).applied(to: $0, in: role) })
        else {
            return false
        }
        guard book.dismiss(id, in: commenting.scene) else {
            if !ranges.isEmpty { _ = rewrite(ranges, by: { CommentEdit.add(id).applied(to: $0, in: role) }) }
            return false
        }
        undo.setActionName(CommentWording.dismissUndoName)
        if comments.comment(in: commenting.scene) == id { comments.deselect() }
        return true
    }

    /// Gives the open scene's comment `id` the text `text`, as one change on the page's undo.
    @discardableResult
    func setText(_ text: String, ofComment id: CommentID) -> Bool {
        guard let commenting else { return false }
        commenting.view.breakUndoCoalescing()
        return book.setText(text, ofComment: id, in: commenting.scene)
    }

    /// Selects the text the open scene's comment `id` covers on the page, and scrolls its start
    /// into view, leaving the focus where it is (PLAN §8.1: clicking a card).
    func selectText(ofComment id: CommentID) {
        guard part == .body, let view = textView, let storage = view.textStorage else { return }
        let ranges = storage.ranges(commentedBy: id)
        guard let first = ranges.first else { return }
        view.selectedRanges = ranges.map(NSValue.init(range:))
        view.scrollRangeToVisible(first)
    }

    /// New Comment from the panel's + button, the page's floating button or the Edit menu: the
    /// comment (`newComment()`), with its card open in the Comments tab and the cursor in it
    /// (PLAN §8.1).
    @discardableResult
    func newCommentInItsCard() -> CommentID? {
        guard let scene, let id = newComment() else { return nil }
        comments.open(id, in: scene)
        preferences.reveal(.comments)
        return id
    }

    /// Recolors the open scene's comment `id`, as one change on the page's undo; the color
    /// becomes the next new comment's.
    @discardableResult
    func recolor(_ id: CommentID, to color: PaletteColor) -> Bool {
        guard let commenting else { return false }
        commenting.view.breakUndoCoalescing()
        guard book.recolor(id, in: commenting.scene, to: color) else { return false }
        preferences.rememberCommentColor(color)
        // In this turn: SwiftUI updates the page on a later pass (the owner's bug A, #25).
        showComments(of: commenting.scene)
        return true
    }

    /// Whether a new comment could cover the page's selection, for Edit → New Comment.
    private var commentTarget: EditorFormatting.CommentTarget {
        guard part == .body, let view = textView, let storage = view.textStorage,
            !storage.commentRanges(selecting: view.selectedRanges.map(\.rangeValue)).isEmpty
        else { return .nothing }
        return .selection
    }

    private typealias Commenting = (scene: SceneID, view: SceneTextView, storage: NSTextStorage)

    /// The page, while its comments can change.
    private var commenting: Commenting? {
        guard part == .body, let scene, let view = textView, view.isEditable, let storage = view.textStorage,
            sync == .inStep
        else { return nil }
        return (scene, view, storage)
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
        formatting.show(formattingSelection, commenting: commentTarget, from: self)
        (textView as? ManuscriptTextView)?.placeCommentButton()
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
            switch part {
            case .body: insert(pasted.lines, adding: pasted.comments)
            case .notes: insert(pasted.lines.map(\.uncommented), adding: [])
            }
            return true
        }
        guard let text = Self.foreignText(on: pasteboard, type: type, typing: view.typingAttributes) else {
            return false
        }
        let lines = RunCodec.paragraphs(from: text).map(\.uncommented)
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
            undo.registerUndo(withTarget: book) { $0.removeComments(ids, from: scene) }
        }
        guard view.shouldChangeText(in: range, replacementString: text.string) else { return }
        addedComments = comments
        storage.replaceCharacters(in: range, with: text)
        addedComments = []
        view.didChangeText()
        view.setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
    }
}

extension Editability {
    /// Editable in an editable book, unless SwiftUI disabled the view, as under a sheet.
    init(_ book: AppOpenBook, in environment: EnvironmentValues) {
        self = book.isEditable && environment.isEnabled ? .editable : .readOnly
    }
}

extension SceneTextEditor: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? {
        scene.map { book.undo(for: $0, part) }
    }

    /// Every typed or replaced string goes through the character policy (ADR 0028). When the
    /// policy changes it, this change is refused and the admitted text put in its place.
    /// (A book that has stopped taking edits was already refused by the view itself:
    /// `KeyboardTextView.editability`.)
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
    /// the view alone. Only breaks inside the edited range change here, so it doesn't grow.
    func textStorage(
        _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard storageEdit == .byTheView else { return }
        let string = textStorage.string as NSString
        let plain = role.typingAttributes
        for index in editedRange.location..<editedRange.upperBound where string.isLineBreak(at: index) {
            let attributes = textStorage.attributes(at: index, effectiveRange: nil)
            // Its paragraph style is `restyleEditedParagraphs`'s.
            var expected = plain
            expected[.paragraphStyle] = attributes[.paragraphStyle]
            if !NSDictionary(dictionary: attributes).isEqual(to: expected) {
                textStorage.setAttributes(expected, range: NSRange(location: index, length: 1))
            }
        }
        restyleLater(editedRange, changeInLength: delta, in: textStorage)
    }

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard storageEdit == .byTheView else { return }
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
