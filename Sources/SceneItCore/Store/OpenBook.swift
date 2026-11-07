import Foundation
import Observation

/// The one open book (ADR 0021): the in-memory `Book`, and, when it's editable, the autosave
/// driver and the writer that saves it. Views read it; every change goes through its methods,
/// which tell autosave in the same main-actor turn.
///
/// It is the driver's `AutosaveSaver`. The driver holds it weakly, so once the store lets go
/// of a book, its driver stops scheduling saves.
@MainActor
@Observable
public final class OpenBook<C: Clock<Duration>>: AutosaveSaver {
    public let layout: PackageLayout
    /// This opening of the book, never shared with another: reopening the same package (Open
    /// Anyway, say) makes a new `OpenBook` at the same `layout`, which the window mustn't take
    /// for the old one.
    @ObservationIgnored public let instanceID = UUID()
    public private(set) var book: Book
    /// Kept in step with `book` by every edit, so the status bar never recounts the book.
    public private(set) var wordCounts: SceneWordCounts
    public private(set) var openScene: SceneID?
    /// The last save that succeeded: when, and what it did for the backups.
    public private(set) var lastSave: (at: Date, backups: SavedBackups?)?
    /// What the File Cabinet lists: `Archive/index.md` reconciled with the filed copies.
    public private(set) var archive: ArchiveIndex
    /// What the last reconciliation noticed.
    public private(set) var archiveNotices: [ArchiveNotice]
    /// What the writer gave copies whose filing couldn't save their section in the index:
    /// recorded by the next save or reconciliation that can write it.
    public private(set) var pendingRecords: [FiledCopyNumber: FilingRecord] = [:]
    /// File a Copy's dialog while it's up (PLAN §7.1): what the writer has typed there, which
    /// leaving the book asks about first.
    public var filingDraft: FilingDraft?
    /// Changes to the book's scenes: added, moved, cut, restored (PLAN §8.6).
    @ObservationIgnored public let structureUndo = UndoManager()
    /// The Errors tab's Delete and Fix (book format §5.4).
    @ObservationIgnored public let errorsUndo = UndoManager()
    @ObservationIgnored private var textUndoManagers: [TextPart: [SceneID: UndoManager]] = [:]
    @ObservationIgnored private var titleUndoManagers: [SceneID: UndoManager] = [:]
    /// The scene each registered structure undo acts on, kept current when an Errors-tab Fix
    /// changes a scene's id, so the undo still finds it.
    @ObservationIgnored private var structureTargets: [StructureTarget: SceneID] = [:]

    private var access: Access
    @ObservationIgnored private weak var store: BookStore<C>?
    @ObservationIgnored private var ids = IDGenerator<SystemRandomNumberGenerator>.system

    private enum Access {
        case writable(AutosaveDriver<C>, BookWriter, Edits)
        case readOnly(ReadOnlyReason)
        case closed
    }

    enum Edits {
        case accepted
        /// While the store writes this book's final copy elsewhere, so nothing typed can miss it.
        case refused
    }

    init(
        _ opened: OpenedBook, archive: ReconciledArchive, clock: C, mirror: BackupMirror, store: BookStore<C>
    ) {
        self.store = store
        book = opened.book
        self.archive = archive.index
        archiveNotices = archive.notices
        wordCounts = SceneWordCounts(opened.book)
        access = .closed
        switch opened {
        case .editing(let editable):
            layout = editable.package.layout
            access = .writable(
                AutosaveDriver(clock: clock, saver: self), BookWriter(editable.package, mirror: mirror),
                .accepted)
        case .readOnly(let readOnly, let reason):
            layout = readOnly.layout
            access = .readOnly(reason)
        }
        openScene = book.scenes.first?.id
    }

    public var status: BookStatus {
        switch access {
        case .writable(let driver, _, _): BookStatus(autosave: driver.state, lastBackups: lastSave?.backups)
        case .readOnly(let reason): .readOnly(reason)
        case .closed: .closed
        }
    }

    public var isEditable: Bool {
        editingDriver != nil
    }

    /// Whether `BookStore.makeEditable()` applies: the book is read-only because it was
    /// repaired as it opened (ADR 0024).
    public var canBeMadeEditable: Bool {
        if case .readOnly(.repairedOnOpen) = access { true } else { false }
    }

    var autosave: AutosaveDriver<C>? {
        if case .writable(let driver, _, _) = access { driver } else { nil }
    }

    /// The driver, while edits are accepted.
    private var editingDriver: AutosaveDriver<C>? {
        if case .writable(let driver, _, .accepted) = access { driver } else { nil }
    }

    /// ADR 0024's Make Editable, once the original is kept: the repaired book is unsaved, so
    /// autosave writes it, replacing the damaged file.
    func becomeEditable(_ writer: BookWriter, clock: C) {
        guard case .readOnly = access else { return }
        let driver = AutosaveDriver(clock: clock, saver: self)
        access = .writable(driver, writer, .accepted)
        driver.send(.edited)
    }

    func show(_ reconciled: ReconciledArchive) {
        archive = reconciled.index
        archiveNotices = reconciled.notices
    }

    func setEdits(_ edits: Edits) {
        if case .writable(let driver, let writer, _) = access { access = .writable(driver, writer, edits) }
    }

    // MARK: Edits

    public func setTitle(of scene: SceneID, to title: SceneTitle) {
        edit(scene) { $0.title = title }
    }

    /// Replaces the whole body, as something other than the page's own editing: the page's
    /// undo history for the scene no longer fits its text, so it's cleared.
    public func replaceBody(of scene: SceneID, with body: [Paragraph]) {
        replace(.body, of: scene, with: body)
    }

    /// `replaceBody(of:with:)` for the notes, whose undo history is cleared likewise.
    public func replaceNotes(of scene: SceneID, with notes: [Paragraph]) {
        replace(.notes, of: scene, with: notes)
    }

    private func replace(_ part: TextPart, of scene: SceneID, with paragraphs: [Paragraph]) {
        var stored: [Paragraph]?
        edit(scene) { scene in
            scene[keyPath: part.paragraphs] = paragraphs
            stored = scene[keyPath: part.paragraphs]
        }
        if let stored, book.scene(scene)?[keyPath: part.paragraphs] == stored {
            textUndoManagers[part]?[scene]?.removeAllActions()
        }
    }

    /// An editor's edit to `scene`'s body or notes, adding `comments` to the scene with it (a
    /// paste onto the page that brings comments along, decisions 0017 and 0035, or a new
    /// comment on the text it covers). Any comment id
    /// the scene then has no comment for is dropped from the new paragraphs, so the book always
    /// saves; the notes take no comment and carry none (ADR 0035). Returns the
    /// paragraphs the part now holds in place of the replaced lines; `nil`, changing nothing,
    /// if the book is read-only, there's no such scene or the lines aren't in the part. Only
    /// the body's words are counted (PLAN §4.5).
    @discardableResult
    public func apply(
        _ change: BodyChange, to scene: SceneID, in part: TextPart = .body, adding comments: [Comment] = []
    ) -> [Paragraph]? {
        guard let driver = editingDriver, let place = place(of: scene) else { return nil }
        var edited = book[keyPath: place.list][place.index]
        let added =
            part == .body
            ? comments.filter { comment in !edited.comments.contains { $0.id == comment.id } } : []
        edited.comments += added
        let known = commentsAllowed(in: part, of: edited)
        let accepted = change.mapParagraphs { $0.keepingComments(known) }
        let text = part.paragraphs
        guard let replaced = accepted.replaced(in: edited[keyPath: text]),
            let paragraphs = accepted.applied(to: edited[keyPath: text])
        else {
            return nil
        }
        guard !added.isEmpty || Array(replaced) != accepted.paragraphs else { return accepted.paragraphs }
        edited[keyPath: text] = paragraphs
        edited.modified = Timestamp(.now, in: .current)
        book[keyPath: place.list][place.index] = edited
        if part == .body {
            wordCounts.adjust(
                scene, removing: WordCount(Array(replaced)), adding: WordCount(accepted.paragraphs))
        }
        driver.send(.edited)
        return accepted.paragraphs
    }

    /// The comment ids `part` of `scene` may carry: the scene's, on the page, and none in the
    /// notes (ADR 0035).
    private func commentsAllowed(in part: TextPart, of scene: BookScene) -> Set<CommentID> {
        switch part {
        case .body: Set(scene.comments.map(\.id))
        case .notes: []
        }
    }

    // MARK: Comments (PLAN §8.1), on the page only (ADR 0035)

    // A comment's text on the page changes as the page's own edit, through
    // `apply(_:to:in:adding:)`, so the page's undo history keeps describing its text; the
    // operations here change only the scene's comment list. Each registers its inverse on the
    // page's undo, where every comment action goes (PLAN §8.6).

    /// A comment for `scene` in `color`, empty and made now, with an id none of its comments
    /// has; `nil` if the book is read-only or has no such scene. It isn't in the scene yet:
    /// the page's edit that covers its text adds it (`apply(_:to:in:adding:)`).
    public func newComment(in scene: SceneID, colored color: PaletteColor) -> Comment? {
        guard editingDriver != nil, let existing = book.scene(scene) else { return nil }
        var id = ids.commentID()
        while existing.comments.contains(where: { $0.id == id }) { id = ids.commentID() }
        return Comment(id: id, color: color, text: "", created: Timestamp(.now, in: .current))
    }

    /// Gives `scene`'s comment `id` the text `text` (as `CharacterPolicy` admits it), as one
    /// change from `original`, the text it had before any `draftText` since; from its text now
    /// when that's `nil`. `false`, changing nothing, if the book is read-only or there's no such
    /// comment.
    @discardableResult
    public func setText(
        _ text: String, ofComment id: CommentID, in scene: SceneID, since original: String? = nil
    ) -> Bool {
        change(
            id, in: scene, named: CommentWording.editUndoName, to: .text(text),
            from: original.map(CommentField.text))
    }

    /// Gives `scene`'s comment `id` the text being typed into its card, so autosave keeps it,
    /// with no undo step: `setText(_:ofComment:in:since:)` registers one for the whole edit
    /// when the card is done. `false`, changing nothing, if the book is read-only or there's no
    /// such comment.
    @discardableResult
    public func draftText(_ text: String, ofComment id: CommentID, in scene: SceneID) -> Bool {
        change(id, in: scene, named: nil, to: .text(text))
    }

    /// Gives `scene`'s comment `id` the color `color`, as one change. `false`, changing
    /// nothing, if the book is read-only or there's no such comment.
    @discardableResult
    public func recolor(_ id: CommentID, in scene: SceneID, to color: PaletteColor) -> Bool {
        change(id, in: scene, named: CommentWording.recolorUndoName, to: .color(color))
    }

    /// Dismisses `scene`'s comment `id` (PLAN §8.1): it's removed from the scene, and undoing
    /// that puts it back where it was. Only a detached comment: the page takes a comment off
    /// its text first (`SceneTextEditor.dismiss`). `false`, changing nothing, if the book is
    /// read-only, there's no such comment or text still carries it.
    @discardableResult
    public func dismiss(_ id: CommentID, in scene: SceneID) -> Bool {
        guard let current = book.scene(scene), current.comments.contains(where: { $0.id == id }),
            current.isDetached(id)
        else { return false }
        return removeComments([id], from: scene, named: CommentWording.dismissUndoName)
    }

    /// Takes `ids` out of `scene`'s comments, except those some text still carries: a paste's
    /// comments, as its undo takes its text away, or a dismissed one. Returns whether it took
    /// any.
    @discardableResult
    public func removeComments(_ ids: Set<CommentID>, from scene: SceneID, named name: String? = nil) -> Bool
    {
        guard let driver = editingDriver, let place = place(of: scene) else { return false }
        let current = book[keyPath: place.list][place.index]
        let removed = current.comments.enumerated().filter {
            ids.contains($1.id) && current.isDetached($1.id)
        }
        guard !removed.isEmpty else { return false }
        for (offset, _) in removed.reversed() {
            book[keyPath: place.list][place.index].comments.remove(at: offset)
        }
        book[keyPath: place.list][place.index].modified = Timestamp(.now, in: .current)
        registerCommentUndo(in: scene, named: name) {
            $0.restoreComments(removed.map { ($0.offset, $0.element) }, to: scene, named: name)
        }
        driver.send(.edited)
        return true
    }

    /// Puts removed comments back at their indices, in ascending order of index.
    private func restoreComments(
        _ comments: [(index: Int, comment: Comment)], to scene: SceneID, named name: String?
    ) {
        guard let driver = editingDriver, let place = place(of: scene) else { return }
        var list = book[keyPath: place.list][place.index].comments
        let restored = comments.filter { entry in !list.contains { $0.id == entry.comment.id } }
        for (index, comment) in restored { list.insert(comment, at: min(index, list.count)) }
        book[keyPath: place.list][place.index].comments = list
        book[keyPath: place.list][place.index].modified = Timestamp(.now, in: .current)
        registerCommentUndo(in: scene, named: name) {
            $0.removeComments(Set(restored.map(\.comment.id)), from: scene, named: name)
        }
        driver.send(.edited)
    }

    /// Gives `scene`'s comment `id` the field `new`, and registers under `name` the change of
    /// that field alone back to `original`, or to what it is now; with no `name`, registers
    /// nothing. An inverse changes only its own field, so undoing an edit of the text never
    /// takes back a recolor made during it, nor the other way round.
    private func change(
        _ id: CommentID, in scene: SceneID, named name: String?, to new: CommentField,
        from original: CommentField? = nil
    ) -> Bool {
        guard let driver = editingDriver, let place = place(of: scene),
            let index = book[keyPath: place.list][place.index].comments.firstIndex(where: { $0.id == id })
        else { return false }
        let current = book[keyPath: place.list][place.index].comments[index]
        let old = original ?? current[new]
        var changed = current
        changed[new] = new
        if changed != current {
            book[keyPath: place.list][place.index].comments[index] = changed
            book[keyPath: place.list][place.index].modified = Timestamp(.now, in: .current)
            driver.send(.edited)
        }
        if let name, old != changed[new] {
            registerCommentUndo(in: scene, named: name) {
                _ = $0.change(id, in: scene, named: name, to: old)
            }
        }
        return true
    }

    private func registerCommentUndo(
        in scene: SceneID, named name: String?, _ inverse: @escaping (OpenBook) -> Void
    ) {
        let undo = pageUndo(for: scene)
        undo.registerUndo(withTarget: self, handler: inverse)
        if let name { undo.setActionName(name) }
    }

    /// The undo history of `scene`'s page or notes (PLAN §8.6), each its own, kept while the
    /// book is open.
    public func undo(for scene: SceneID, _ part: TextPart) -> UndoManager {
        Self.manager(for: scene, in: &textUndoManagers[part, default: [:]])
    }

    public func pageUndo(for scene: SceneID) -> UndoManager {
        undo(for: scene, .body)
    }

    public func notesUndo(for scene: SceneID) -> UndoManager {
        undo(for: scene, .notes)
    }

    /// The undo history of `scene`'s title field, kept while the book is open.
    public func titleUndo(for scene: SceneID) -> UndoManager {
        Self.manager(for: scene, in: &titleUndoManagers)
    }

    private static func manager(for scene: SceneID, in managers: inout [SceneID: UndoManager]) -> UndoManager
    {
        if let manager = managers[scene] { return manager }
        let manager = UndoManager()
        managers[scene] = manager
        return manager
    }

    /// `clip` as pasting it into `scene` writes it (decision 0017): its lines, and the comments
    /// the paste adds to the scene, copied with fresh ids where they must be. Pass both to
    /// `apply(_:to:adding:)`.
    public func resolve(_ clip: PageClip, into scene: SceneID) -> (lines: [Paragraph], comments: [Comment])? {
        guard let destination = book.scene(scene) else { return nil }
        return clip.resolved(into: destination, ids: &ids)
    }

    /// Adds an untitled scene after `scene` (at the end if `nil` or not in the story) and opens it.
    @discardableResult
    public func addScene(after scene: SceneID?) -> SceneID? {
        guard let driver = editingDriver else { return nil }
        let new = BookScene(id: ids.sceneID(), modified: Timestamp(.now, in: .current), title: "")
        let index = scene.flatMap { id in book.scenes.firstIndex { $0.id == id } }.map { $0 + 1 }
        book.scenes.insert(new, at: index ?? book.scenes.endIndex)
        wordCounts.recount(new)
        driver.send(.edited)
        select(new.id)
        return new.id
    }

    /// Deletes a Boneyard scene as far as the writer can tell (ADR 0031): it moves to the
    /// book's Deleted section, which the app never shows, and stays in the file with its
    /// id, notes and comments. One change on `structureUndo`. `false`, changing nothing, if
    /// the book is read-only or the Boneyard has no such scene.
    @discardableResult
    public func deleteFromBoneyard(_ scene: SceneID) -> Bool {
        let target = StructureTarget()
        structureTargets[target] = scene
        return delete(target)
    }

    private func delete(_ target: StructureTarget) -> Bool {
        guard editingDriver != nil, let scene = structureTargets[target],
            book.boneyard.contains(where: { $0.id == scene })
        else { return false }
        if openScene == scene { select(nil) }
        // Leaving the scene may have saved what was typed into it, so look it up again.
        guard let driver = editingDriver, let index = book.delete(fromBoneyard: scene) else { return false }
        structureUndo.registerUndo(withTarget: self) { $0.undelete(target, toBoneyardAt: index) }
        structureUndo.setActionName(BoneyardWording.deleteUndoName)
        driver.send(.edited)
        return true
    }

    private func undelete(_ target: StructureTarget, toBoneyardAt index: Int) {
        guard let driver = editingDriver, let scene = structureTargets[target],
            book.undelete(scene, toBoneyardAt: index)
        else { return }
        structureUndo.registerUndo(withTarget: self) { _ = $0.delete(target) }
        structureUndo.setActionName(BoneyardWording.deleteUndoName)
        driver.send(.edited)
    }

    /// Opens `scene`. Every way of opening another scene comes here; it first posts
    /// `openBookWillSwitchScene`, so the window can finish what's being typed into the scene
    /// it's leaving while that scene is still the open one. (An Errors-tab fix that changes
    /// the open scene's id keeps that scene open, so it doesn't come here.)
    public func select(_ scene: SceneID?) {
        guard scene != openScene else { return }
        NotificationCenter.default.post(name: .openBookWillSwitchScene, object: self)
        openScene = scene
        autosave?.send(.sceneSwitched)
    }

    /// Where the scene with this id is: in the story or the Boneyard, and at which index.
    private func place(of id: SceneID) -> (list: WritableKeyPath<Book, [BookScene]>, index: Int)? {
        book.visiblePlace(of: id).map { ($0.part.scenes, $0.index) }
    }

    private func edit(_ id: SceneID, _ change: (inout BookScene) -> Void) {
        guard let driver = editingDriver, let (list, index) = place(of: id) else { return }
        var scene = book[keyPath: list][index]
        change(&scene)
        guard scene != book[keyPath: list][index] else { return }
        scene.modified = Timestamp(.now, in: .current)
        let bodyChanged = scene.body != book[keyPath: list][index].body
        book[keyPath: list][index] = scene
        if bodyChanged { wordCounts.recount(scene) }
        driver.send(.edited)
    }

    // MARK: Filing a copy (PLAN §7.1)

    /// Saves every edit so far, then files a copy of the book. Only while it's editable.
    func fileCopy(as record: FilingRecord) async -> FilingResult {
        guard let driver = editingDriver, case .writable(_, let writer, _) = access else {
            return .unavailable
        }
        let verdict: QuitVerdict
        do {
            verdict = try await driver.saveAndWait()
        } catch {
            return .failed(.stillSaving)
        }
        switch verdict {
        case .terminate: break
        case .askWriter(.saveFailed(let error)), .askWriter(.changedOnDisk(let error)):
            return .failed(.save(error))
        case .askWriter(.stillSaving): return .failed(.stillSaving)
        }
        guard editingDriver != nil else { return .unavailable }
        let result: FilingResult
        do throws(FilingFailure) {
            let outcome = try await writer.fileCopy(of: book, as: record, pending: pendingRecords)
            switch outcome.index {
            case .updated(let index):
                forgetPending(recordedIn: index)
            case .notUpdated(.couldNotRead), .notUpdated(.notWritten):
                pendingRecords[outcome.number] = record
            case .notUpdated(.newerFormat):
                break
            }
            result = .filed(outcome)
        } catch .unavailable {
            result = .unavailable
        } catch {
            result = .failed(error)
        }
        if let reconciled = await writer.reconcileArchive(.readOnly, pending: pendingRecords) {
            show(reconciled)
        }
        return result
    }

    /// Records the pending records, if any, now that a save may have cleared what stopped them.
    private func recordPending(_ writer: BookWriter) async {
        guard !pendingRecords.isEmpty,
            let reconciled = await writer.reconcileArchive(.writable, pending: pendingRecords)
        else { return }
        show(reconciled)
        if reconciled.isSaved { forgetPending(recordedIn: reconciled.index) }
    }

    private func forgetPending(recordedIn index: ArchiveIndex) {
        for copy in index.copies { pendingRecords[copy.number] = nil }
    }

    // MARK: Error entries (book format §5.4)

    public enum EntryEdit: Hashable, Sendable {
        /// The edited entry took effect and left the Errors tab.
        case repaired
        /// The entry stays, holding the edited payload.
        case kept(ErrorReason)
        /// The book is read-only, the entry is no longer where the row said, or it can't be
        /// repaired.
        case refused
    }

    // Entry operations act on the book's text through the file format, not as typing, so they
    // leave every scene's `modified` as it is. Each registers, on `errorsUndo`, only the
    // inverse of its own change, so undoing it keeps whatever was typed in that scene since.

    @discardableResult
    public func deleteError(_ ref: ErrorRef) -> Bool {
        guard editingDriver != nil, book.holds(ref), let part = book.part(ref.owner) else { return false }
        var errors = part.errors
        errors.remove(at: ref.index)
        commit(ref.owner, part.with(errors: errors), named: ErrorsWording.deleteUndoName) {
            $0.reinsert(ref.entry, at: ref.index, in: ref.owner)
        }
        return true
    }

    @discardableResult
    public func repairError(_ ref: ErrorRef, as payload: String) -> EntryEdit {
        guard editingDriver != nil, let old = book.part(ref.owner),
            let repair = BookFormat.repair(ref, as: payload, in: book)
        else {
            return .refused
        }
        switch repair {
        case .repaired(let part):
            let effect = RepairEffect(from: old, to: part)
            commit(ref.owner, part, named: ErrorsWording.fixUndoName) {
                $0.unrepair(effect, restoring: ref.entry, at: ref.index, in: part.owner, payload: payload)
            }
            return .repaired
        case .kept(let part, let reason):
            let edited = part.errors[ref.index]
            commit(ref.owner, part, named: ErrorsWording.fixUndoName) {
                $0.unedit(ErrorRef(owner: ref.owner, index: ref.index, entry: edited), back: ref.entry)
            }
            return .kept(reason)
        }
    }

    private func reinsert(_ entry: ErrorEntry, at index: Int, in owner: ErrorOwner) {
        guard let part = book.part(owner) else { return }
        var errors = part.errors
        let at = min(index, errors.count)
        errors.insert(entry, at: at)
        commit(owner, part.with(errors: errors)) {
            $0.deleteError(ErrorRef(owner: owner, index: at, entry: entry))
        }
    }

    private func unrepair(
        _ effect: RepairEffect, restoring entry: ErrorEntry, at index: Int, in owner: ErrorOwner,
        payload: String
    ) {
        guard let part = book.part(owner) else { return }
        let undone = effect.undone(in: part)
        var errors = undone.errors
        let at = min(index, errors.count)
        errors.insert(entry, at: at)
        let restored = undone.with(errors: errors)
        commit(owner, restored) {
            $0.repairError(ErrorRef(owner: restored.owner, index: at, entry: entry), as: payload)
        }
    }

    private func unedit(_ ref: ErrorRef, back original: ErrorEntry) {
        guard book.holds(ref), let part = book.part(ref.owner) else { return }
        var errors = part.errors
        errors[ref.index] = original
        commit(ref.owner, part.with(errors: errors)) {
            $0.repairError(
                ErrorRef(owner: ref.owner, index: ref.index, entry: original), as: ref.entry.payload)
        }
    }

    /// Puts `part` in place of `owner`'s, and registers `inverse` as its undo, named `name`
    /// when given. A part that changes nothing registers nothing, and names nothing, so it
    /// can't rename the operation before it.
    private func commit(
        _ owner: ErrorOwner, _ part: BookPart, named name: String? = nil,
        inverse: @escaping (OpenBook) -> Void
    ) {
        let old = book.part(owner)
        guard let driver = editingDriver, old != part, book.replace(owner, with: part) else {
            return
        }
        if case .scene(let scene) = part {
            wordCounts.recount(scene)
            if case .scene(let before) = old {
                for part in TextPart.allCases
                where before[keyPath: part.paragraphs] != scene[keyPath: part.paragraphs] {
                    textUndoManagers[part]?[before.id]?.removeAllActions()
                }
            }
            if owner == openScene.map(ErrorOwner.scene) { openScene = scene.id }
            if case .scene(let id) = owner, id != scene.id {
                for (target, held) in structureTargets where held == id {
                    structureTargets[target] = scene.id
                }
            }
        }
        errorsUndo.registerUndo(withTarget: self, handler: inverse)
        if let name { errorsUndo.setActionName(name) }
        driver.send(.edited)
    }

    // MARK: Saving

    public func save(_ request: SaveRequest) async throws(SaveError) {
        // Unreachable in practice: closing a book drops its driver, the only caller.
        guard case .writable(_, let writer, _) = access else {
            throw .fileSystem(FileSystemError(.write, layout.book, .notFound))
        }
        let snapshot = book
        do {
            let result = try await writer.save(snapshot, onExternalChange: request.onExternalChange)
            let backups: SavedBackups? =
                switch result {
                case .unchanged: lastSave?.backups
                case .saved(let backups): backups
                }
            let now = Date.now
            lastSave = (now, backups)
            store?.bookSaved(at: now)
            await recordPending(writer)
        } catch {
            Log.store.error("a save failed", ["error": .error(LoggedError(error))])
            // Runs after the driver has handled this failure, so it sees the pause, if any.
            Task { [weak self] in
                guard let self, case .paused = self.autosave?.state else { return }
                await self.store?.askAboutExternalChange(in: self)
            }
            throw error
        }
    }

    /// Before the writer leaves the book: if File a Copy's dialog holds typed text, asks whether
    /// to leave it unfiled. The draft stays as it is either way; it goes with the book only if
    /// the book really is left, so a leave that fails later (a save, the next book) loses nothing.
    func confirmLeaving(_ leaving: Leaving, asking prompts: any StorePrompts) async -> LeaveConfirmation {
        guard let draft = filingDraft, draft.holdsTypedText else { return .leave }
        switch await prompts.ask(ArchiveWording.unfiledDraftAlert(draft.record, leaving: leaving)) {
        case .cancel: return .stay
        case .leaveAnyway: return .leave
        }
    }

    enum LeaveConfirmation {
        case leave
        case stay
    }

    /// Saves before the writer leaves the book, asking whenever that would lose edits.
    func settle(before leaving: Leaving, asking prompts: any StorePrompts) async -> Settled {
        guard let driver = autosave else { return .saved }
        while true {
            let verdict: QuitVerdict
            do {
                verdict = try await driver.prepareToQuit()
            } catch {
                return .stay
            }
            switch verdict {
            case .terminate:
                if driver.state.quitDecision == .settled(.terminate) { return .saved }
            case .askWriter(let problem):
                switch await prompts.ask(QuitWording.alert(for: problem, leaving: leaving)) {
                case .retry, .wait: continue
                case .quitAnyway: return .discarding
                case .cancel: return .stay
                }
            }
        }
    }

    enum Settled {
        /// Every edit is on disk (or the book is read-only).
        case saved
        /// The writer chose to leave without saving.
        case discarding
        case stay
    }

    func keepMyVersion() {
        autosave?.send(.externalChangeResolved)
    }

    func saveNow() {
        autosave?.send(.saveCommand)
    }

    func appDeactivated() {
        autosave?.send(.appDeactivated)
    }

    /// Closes the book at once, synchronously: from here on it refuses every edit, and its
    /// driver is dropped. The caller releases the returned writer (`BookStore.release`).
    func detach() -> BookWriter? {
        defer { access = .closed }
        if case .writable(_, let writer, _) = access { return writer } else { return nil }
    }
}

/// Names the scene of one structure change for its undo and redo, whatever its id becomes.
private struct StructureTarget: Hashable {
    let id = UUID()
}

extension OpenBook {
    public var location: SceneLocation {
        SceneLocation(of: openScene, in: book)
    }

    /// The manuscript's words, from the per-scene counts.
    public var manuscriptWordCount: WordCount {
        wordCounts.manuscript(of: book)
    }
}

extension Notification.Name {
    /// Posted by `OpenBook.select(_:)` just before another scene opens, with the book as its
    /// object.
    public static let openBookWillSwitchScene = Notification.Name("OpenBookWillSwitchScene")
}

/// One field of a comment the writer can change, with its value.
private enum CommentField: Equatable {
    case text(String)
    case color(PaletteColor)
}

extension Comment {
    /// The field of the same kind as `field`, as this comment has it; set, `field`'s value.
    fileprivate subscript(field: CommentField) -> CommentField {
        get {
            switch field {
            case .text: .text(text)
            case .color: .color(color)
            }
        }
        set {
            switch newValue {
            case .text(let text): self.text = text
            case .color(let color): self.color = color
            }
        }
    }
}
