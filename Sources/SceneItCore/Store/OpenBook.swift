import Foundation
import Observation

/// The one open book (ADR 0021): the in-memory `Book`, and, when it's editable, the autosave
/// driver and the writer that saves it. Views read it; every change goes through its methods,
/// which tell autosave in the same main-actor turn.
///
/// A review is open as a book too (ADR 0042): the copy's text, which nothing changes, with the
/// reviewer's comments and notes, saved to the review's file. What the writer may change is
/// `accepts(_:)`.
///
/// It is the driver's `AutosaveSaver`. The driver holds it weakly, so once the store lets go
/// of a book, its driver stops scheduling saves.
@MainActor
@Observable
public final class OpenBook<C: Clock<Duration>>: AutosaveSaver {
    public let document: OpenDocument
    /// This opening of the book, never shared with another: reopening the same package (Open
    /// Anyway, say) makes a new `OpenBook` at the same `layout`, which the window mustn't take
    /// for the old one.
    @ObservationIgnored public let instanceID = UUID()
    /// The package's identity as the book opened, which a rename or move in Finder doesn't
    /// change; `nil` if it couldn't be identified.
    @ObservationIgnored let packageIdentity: MountedIdentity?
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
    public private(set) var pendingRecords: [FiledCopyNumber: PendingRecord] = [:]
    /// File a Copy's dialog while it's up (PLAN §7.1): what the writer has typed there, which
    /// leaving the book asks about first.
    public var filingDraft: FilingDraft?
    /// Pending records whose copies the index turned out to give other sections, or whose
    /// numbers turned out to hold other files (another program wrote them): forgotten, for the
    /// store to tell the writer. A number can appear twice.
    @ObservationIgnored private var overwrittenRecords: UnrecordedCopies = []
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
        case writable(AutosaveDriver<C>, DocumentWriter, Edits)
        case readOnly(ReadOnlyReason)
        case closed
    }

    enum Edits {
        case accepted
        /// While the store writes this book's final copy elsewhere, so nothing typed can miss it.
        case refused
    }

    /// `pending`: the records the book this one replaces still had pending; `archive` was
    /// reconciled with them.
    init(
        _ opened: OpenedBook, identity: MountedIdentity?, archive: ReconciledArchive,
        pending: Archive.Pending,
        clock: C, mirror: BackupMirror, store: BookStore<C>
    ) {
        self.store = store
        packageIdentity = identity
        book = opened.book
        self.archive = archive.index
        archiveNotices = archive.notices
        wordCounts = SceneWordCounts(opened.book)
        access = .closed
        switch opened {
        case .editing(let editable):
            document = .book(editable.package.layout)
            access = .writable(
                AutosaveDriver(clock: clock, saver: self),
                .book(BookWriter(editable.package, mirror: mirror)),
                .accepted)
        case .readOnly(let readOnly, let reason):
            document = .book(readOnly.layout)
            access = .readOnly(reason)
        }
        pendingRecords = pending
        settlePending(against: archive.indexToWrite, isEditable && archive.isSaved ? .saved : .notSaved)
        openScene = book.scenes.first?.id
    }

    /// A review, as Review Book… opened it (ADR 0042). It has no archive.
    init(_ review: LoadedReview, clock: C, store: BookStore<C>) {
        self.store = store
        packageIdentity = nil
        book = review.book
        archive = ArchiveIndex()
        archiveNotices = []
        wordCounts = SceneWordCounts(review.book)
        document = .review(review.context)
        access = .closed
        switch review.access {
        case .editing(let file):
            access = .writable(
                AutosaveDriver(clock: clock, saver: self), .review(ReviewWriter(file, review.context)),
                .accepted)
        case .readOnly(let reason):
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

    /// Whether the writer can make `edit` now: the book takes edits, and a review takes any but
    /// changes to the copy's text (ADR 0042).
    public func accepts(_ edit: EditKind) -> Bool {
        driver(for: edit) != nil
    }

    /// The driver, while `edit` is accepted.
    private func driver(for edit: EditKind) -> AutosaveDriver<C>? {
        guard let driver = editingDriver else { return nil }
        switch (document, edit) {
        case (.review, .manuscript): return nil
        case (.book, _), (.review, .annotations), (.review, .errors): return driver
        }
    }

    /// What Copy Review and Save Review… put out for the review as it is now (review format §5);
    /// `nil` for a book, or a review with nothing to put out yet.
    public func reviewReport(on day: CalendarDay) -> ReviewReport? {
        guard let review, review.hasReport else { return nil }
        return ReviewReport(review, on: day)
    }

    /// Whether Copy Review and Save Review… have anything to put out.
    public var hasReviewReport: Bool {
        review?.hasReport == true
    }

    /// The review as it is now; `nil` for a book.
    private var review: Review? {
        guard case .review(let context) = document else { return nil }
        return context.review(of: book)
    }

    /// Gives the scene at `index` of `list` the time it was changed. A review's scenes keep the copy's.
    private func stamp(_ list: WritableKeyPath<Book, [BookScene]>, _ index: Int) {
        guard case .book = document else { return }
        book[keyPath: list][index].modified = Timestamp(.now, in: .current)
    }

    /// ADR 0024's Make Editable, once the original is kept: the repaired book is unsaved, so
    /// autosave writes it, replacing the damaged file.
    func becomeEditable(_ writer: DocumentWriter, clock: C) {
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
        edit(scene, .manuscript) { $0.title = title }
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
        edit(scene, part.editKind) { scene in
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
        guard editingDriver != nil, let place = place(of: scene) else { return nil }
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
        let kind =
            part == .body && Self.changesOnlyComments(from: Array(replaced), to: accepted.paragraphs)
            ? EditKind.annotations : part.editKind
        guard let driver = driver(for: kind) else { return nil }
        edited[keyPath: text] = paragraphs
        book[keyPath: place.list][place.index] = edited
        stamp(place.list, place.index)
        if part == .body {
            wordCounts.adjust(
                scene, removing: WordCount(Array(replaced)), adding: WordCount(accepted.paragraphs))
        }
        driver.send(.edited)
        return accepted.paragraphs
    }

    /// Whether `new` is `old` with only its comments changed: the same text in the same styles,
    /// colors and highlights. A review's text takes only such changes (ADR 0042).
    /// Text is compared code unit for code unit: `String ==` would call canonically equivalent
    /// spellings the same.
    static func changesOnlyComments(from old: [Paragraph], to new: [Paragraph]) -> Bool {
        let before = old.map { $0.uncommented.withMaximalRuns.runs }
        let after = new.map { $0.uncommented.withMaximalRuns.runs }
        return before.count == after.count
            && zip(before, after).allSatisfy { first, second in
                first.count == second.count
                    && zip(first, second).allSatisfy { run, other in
                        run.hasSameFormat(as: other) && run.text.utf8.elementsEqual(other.text.utf8)
                    }
            }
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
        guard accepts(.annotations), let existing = book.scene(scene) else { return nil }
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
        guard let driver = driver(for: .annotations), let place = place(of: scene) else { return false }
        let current = book[keyPath: place.list][place.index]
        let removed = current.comments.enumerated().filter {
            ids.contains($1.id) && current.isDetached($1.id)
        }
        guard !removed.isEmpty else { return false }
        for (offset, _) in removed.reversed() {
            book[keyPath: place.list][place.index].comments.remove(at: offset)
        }
        stamp(place.list, place.index)
        registerPageUndo(in: scene, named: name) {
            $0.restoreComments(removed.map { ($0.offset, $0.element) }, to: scene, named: name)
        }
        driver.send(.edited)
        return true
    }

    /// Puts removed comments back at their indices, in ascending order of index.
    private func restoreComments(
        _ comments: [(index: Int, comment: Comment)], to scene: SceneID, named name: String?
    ) {
        guard let driver = driver(for: .annotations), let place = place(of: scene) else { return }
        var list = book[keyPath: place.list][place.index].comments
        let restored = comments.filter { entry in !list.contains { $0.id == entry.comment.id } }
        if restored.count != comments.count {
            // A backstop the page history's invariant (ADR 0040) should make unreachable.
            Log.store.error(
                "a comment undo found comments it restores already in the scene; skipping them",
                ["comments": .count(comments.count), "restored": .count(restored.count)])
        }
        for (index, comment) in restored { list.insert(comment, at: min(index, list.count)) }
        book[keyPath: place.list][place.index].comments = list
        stamp(place.list, place.index)
        registerPageUndo(in: scene, named: name) {
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
        guard let driver = driver(for: .annotations), let place = place(of: scene),
            let index = book[keyPath: place.list][place.index].comments.firstIndex(where: { $0.id == id })
        else { return false }
        let current = book[keyPath: place.list][place.index].comments[index]
        let old = original ?? current[new]
        var changed = current
        changed[new] = new
        if changed != current {
            book[keyPath: place.list][place.index].comments[index] = changed
            stamp(place.list, place.index)
            driver.send(.edited)
        }
        if let name, old != changed[new] {
            registerPageUndo(in: scene, named: name) {
                _ = $0.change(id, in: scene, named: name, to: old)
            }
        }
        return true
    }

    private func registerPageUndo(
        in scene: SceneID, named name: String?, _ inverse: @escaping (OpenBook) -> Void
    ) {
        let undo = pageUndo(for: scene)
        undo.registerUndo(withTarget: self, handler: inverse)
        // An undo or redo keeps the name of the step it takes back: an inverse run later in it
        // would rename a dismiss that committed an edit first "Edit Comment".
        if let name, !undo.isUndoing, !undo.isRedoing { undo.setActionName(name) }
    }

    // MARK: Tags (PLAN §8.3), on the page's undo like comments (the owner, #20)

    /// The tags of the scenes the writer can see, most-used first.
    public var tags: BookTags {
        BookTags(book)
    }

    /// The + tag field's Return: adds the tag the writer typed (`BookTags.spelling(of:)`) at the
    /// end of `scene`'s tags, as one change on its page's undo. `false`, changing nothing, if the
    /// book is read-only, there's no such scene, `typed` is no tag or the scene already has it
    /// in any case.
    @discardableResult
    public func addTag(_ typed: String, to scene: SceneID) -> Bool {
        guard let tag = tags.spelling(of: typed) else { return false }
        return add(tag, to: scene)
    }

    /// Takes `tag` off `scene` in every case it has it in, as one change on its page's undo,
    /// which puts each back where it was. `false`, changing nothing, if the book is read-only,
    /// there's no such scene or it hasn't the tag.
    @discardableResult
    public func removeTag(_ tag: String, from scene: SceneID) -> Bool {
        guard let current = book.scene(scene) else { return false }
        let variants = current.tags.enumerated().filter { SceneTag.key($0.element) == SceneTag.key(tag) }
        guard !variants.isEmpty else { return false }
        return takeTags(
            variants.map { ($0.offset, $0.element) }, from: scene, named: TagWording.removeUndoName)
    }

    /// A row of the book's tags clicked: `tag`, exactly as the book spells it, is removed from
    /// `scene` if it has it in any case, and added if not.
    @discardableResult
    public func toggleTag(_ tag: String, on scene: SceneID) -> Bool {
        guard let current = book.scene(scene) else { return false }
        return SceneTag.contains(current.tags, tag) ? removeTag(tag, from: scene) : add(tag, to: scene)
    }

    private func add(_ tag: String, to scene: SceneID) -> Bool {
        guard let current = book.scene(scene), !SceneTag.contains(current.tags, tag) else { return false }
        return putTags([(current.tags.count, tag)], in: scene, named: TagWording.addUndoName)
    }

    // Each primitive registers the other with exactly the pairs it changed. Nothing changes a
    // scene's tags outside its page undo without clearing that history (`commit`), so an inverse
    // always finds the tags as its edit left them.

    /// Removes the recorded (index, spelling) pairs, from the highest index down. Registers
    /// putting back what it removed, if it removed anything.
    private func takeTags(_ tags: [(index: Int, tag: String)], from scene: SceneID, named name: String)
        -> Bool
    {
        guard let driver = driver(for: .manuscript), let place = place(of: scene) else { return false }
        var list = book[keyPath: place.list][place.index].tags
        let removed = tags.sorted { $0.index > $1.index }.filter {
            list.indices.contains($0.index) && list[$0.index] == $0.tag
        }
        if removed.count != tags.count {
            // A backstop the invariant above should make unreachable: only the pairs still where
            // their step left them are taken.
            Log.store.error(
                "a tag undo found the scene's tags changed under it; taking only what still matches",
                ["recorded": .count(tags.count), "matched": .count(removed.count)])
        }
        guard !removed.isEmpty else { return false }
        for (index, _) in removed { list.remove(at: index) }
        book[keyPath: place.list][place.index].tags = list
        stamp(place.list, place.index)
        let restore = Array(removed.reversed())
        registerPageUndo(in: scene, named: name) { _ = $0.putTags(restore, in: scene, named: name) }
        driver.send(.edited)
        return true
    }

    /// Inserts the recorded (index, spelling) pairs, from the lowest index up, each at its index
    /// or the end. Registers taking away what it put.
    private func putTags(_ tags: [(index: Int, tag: String)], in scene: SceneID, named name: String) -> Bool {
        guard let driver = driver(for: .manuscript), let place = place(of: scene), !tags.isEmpty else {
            return false
        }
        var list = book[keyPath: place.list][place.index].tags
        var put: [(index: Int, tag: String)] = []
        for (index, tag) in tags.sorted(by: { $0.index < $1.index }) {
            let at = min(index, list.count)
            list.insert(tag, at: at)
            put.append((at, tag))
        }
        book[keyPath: place.list][place.index].tags = list
        stamp(place.list, place.index)
        registerPageUndo(in: scene, named: name) { _ = $0.takeTags(put, from: scene, named: name) }
        driver.send(.edited)
        return true
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
    /// One change on `structureUndo`, whose undo takes the scene out again and reopens the scene
    /// that was open, if it still can.
    @discardableResult
    public func addScene(after scene: SceneID?) -> SceneID? {
        guard accepts(.manuscript) else { return nil }
        let new = BookScene(id: ids.sceneID(), modified: Timestamp(.now, in: .current), title: "")
        let index = scene.flatMap { id in book.scenes.firstIndex { $0.id == id } }.map { $0 + 1 }
        let target = StructureTarget()
        structureTargets[target] = new.id
        let added = put(target, .held(new), at: index ?? book.scenes.endIndex, returningTo: openScene)
        return added ? new.id : nil
    }

    /// Where an added scene is while its add is undone.
    private enum Unadded {
        /// Here, since it held nothing the writer wrote but perhaps a title (ADR 0041).
        case held(BookScene)
        /// In the book's Deleted section (ADR 0031), where the file keeps what the writer wrote
        /// in it (ADR 0041).
        case deleted
    }

    /// Puts the added scene into the story at `index` (or its end) and opens it; registers taking
    /// it out again.
    private func put(
        _ target: StructureTarget, _ from: Unadded, at index: Int, returningTo previous: SceneID?
    ) -> Bool {
        guard let driver = driver(for: .manuscript), let id = structureTargets[target] else { return false }
        switch from {
        case .held(let held):
            book.scenes.insert(held, at: min(index, book.scenes.count))
        case .deleted:
            guard book.undelete(id, to: .story, at: index) else { return false }
        }
        guard let scene = book.scene(id) else { return false }
        wordCounts.recount(scene)
        structureUndo.registerUndo(withTarget: self) { $0.takeOut(target, returningTo: previous) }
        structureUndo.setActionName(ScenesWording.newSceneUndoName)
        driver.send(.edited)
        select(scene.id)
        return true
    }

    /// Undoes an add: takes the scene out of the story, reopening `previous` if the scene was
    /// open. A scene holding anything the writer wrote but a title goes to the Deleted section
    /// rather than away (ADR 0041). Registers putting it back.
    private func takeOut(_ target: StructureTarget, returningTo previous: SceneID?) {
        guard accepts(.manuscript), let id = structureTargets[target],
            book.scenes.contains(where: { $0.id == id })
        else { return }
        if openScene == id { select(book.scene(previous)?.id) }
        // Leaving the scene may have saved what was typed into it, so look it up again.
        guard let driver = driver(for: .manuscript),
            let index = book.scenes.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let unadded: Unadded
        if book.scenes[index].isBlankButForItsTitle {
            unadded = .held(book.scenes.remove(at: index))
        } else {
            guard book.delete(id, from: .story) != nil else { return }
            unadded = .deleted
        }
        structureUndo.registerUndo(withTarget: self) {
            _ = $0.put(target, unadded, at: index, returningTo: previous)
        }
        structureUndo.setActionName(ScenesWording.newSceneUndoName)
        driver.send(.edited)
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
        guard accepts(.manuscript), let scene = structureTargets[target],
            book.boneyard.contains(where: { $0.id == scene })
        else { return false }
        if openScene == scene { select(nil) }
        // Leaving the scene may have saved what was typed into it, so look it up again.
        guard let driver = driver(for: .manuscript), let index = book.delete(scene, from: .boneyard) else {
            return false
        }
        structureUndo.registerUndo(withTarget: self) { $0.undelete(target, toBoneyardAt: index) }
        structureUndo.setActionName(BoneyardWording.deleteUndoName)
        driver.send(.edited)
        return true
    }

    private func undelete(_ target: StructureTarget, toBoneyardAt index: Int) {
        guard let driver = driver(for: .manuscript), let scene = structureTargets[target],
            book.undelete(scene, to: .boneyard, at: index)
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

    private func edit(_ id: SceneID, _ kind: EditKind, _ change: (inout BookScene) -> Void) {
        guard let driver = driver(for: kind), let (list, index) = place(of: id) else { return }
        var scene = book[keyPath: list][index]
        change(&scene)
        guard scene != book[keyPath: list][index] else { return }
        let bodyChanged = scene.body != book[keyPath: list][index].body
        book[keyPath: list][index] = scene
        stamp(list, index)
        if bodyChanged { wordCounts.recount(book[keyPath: list][index]) }
        driver.send(.edited)
    }

    // MARK: Filing a copy (PLAN §7.1)

    /// Saves every edit so far, then files a copy of the book. Only while it's editable.
    func fileCopy(as record: FilingRecord) async -> FilingResult {
        guard let driver = editingDriver, case .writable(_, .book(let writer), _) = access else {
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
            forgetPending(at: outcome.number, filedAgainAs: record)
            switch outcome.index {
            case .updated(let index):
                settlePending(against: index, .saved)
            case .notUpdated(.couldNotRead), .notUpdated(.notWritten):
                pendingRecords[outcome.number] = PendingRecord(record, digest: outcome.digest)
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
            settlePending(against: reconciled.indexToWrite, .notSaved)
        }
        return result
    }

    /// A new copy was filed as `number`, which was free, so the file a pending record there
    /// was given is gone (another program emptied `Archive/`). Unless the writer gave the new
    /// copy the same record, the old one moves to `overwrittenRecords`.
    private func forgetPending(at number: FiledCopyNumber, filedAgainAs record: FilingRecord) {
        guard let earlier = pendingRecords.removeValue(forKey: number), earlier.record != record else {
            return
        }
        overwritten([(number, earlier.record)])
    }

    /// Records the pending records, if any, now that a save may have cleared what stopped them.
    func recordPending(_ writer: BookWriter) async {
        guard !pendingRecords.isEmpty else { return }
        await reconcileArchive(with: writer)
    }

    /// Reconciles the archive through `writer`, which holds this book's lock, recording the
    /// pending records, and shows it.
    func reconcileArchive(with writer: BookWriter) async {
        guard let reconciled = await writer.reconcileArchive(.writable, pending: pendingRecords) else {
            return
        }
        show(reconciled)
        settlePending(against: reconciled.indexToWrite, reconciled.isSaved ? .saved : .notSaved)
    }

    private enum IndexState {
        case saved
        case notSaved
    }

    /// Forgets the pending records `index` holds, once it's saved. A copy that `index` gives
    /// a section of its own (another program wrote it), or lists without its record (a
    /// different file has its number), keeps that section, and its record moves to
    /// `overwrittenRecords`. A copy `index` leaves out keeps its record pending.
    private func settlePending(against index: ArchiveIndex, _ state: IndexState) {
        var overwritten: UnrecordedCopies = []
        for copy in index.copies {
            guard let pending = pendingRecords[copy.number] else { continue }
            if !copy.holds(pending.record) {
                overwritten.append((copy.number, pending.record))
                pendingRecords[copy.number] = nil
            } else if state == .saved {
                pendingRecords[copy.number] = nil
            }
        }
        self.overwritten(overwritten)
    }

    private func overwritten(_ records: UnrecordedCopies) {
        guard !records.isEmpty else { return }
        Log.store.error(
            "the archive has other sections or files for filed copies whose records were pending",
            ["count": .count(records.count)])
        overwrittenRecords += records
    }

    /// The records the store must tell the writer about now, emptied as they're taken.
    /// `leaving` adds the ones still pending, which nothing will record once the book is gone.
    func takeRecordsToTell(_ leaving: PendingFate) -> UnrecordedCopies {
        defer { overwrittenRecords = [] }
        switch leaving {
        case .kept: return overwrittenRecords
        case .lost:
            return overwrittenRecords + pendingRecords.map { (number: $0.key, record: $0.value.record) }
        }
    }

    enum PendingFate {
        /// This book, or the book read again in its place, still holds them.
        case kept
        case lost
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
        guard accepts(.errors), book.holds(ref), let part = book.part(ref.owner) else { return false }
        var errors = part.errors
        errors.remove(at: ref.index)
        commit(ref.owner, part.with(errors: errors), named: ErrorsWording.deleteUndoName) {
            $0.reinsert(ref.entry, at: ref.index, in: ref.owner)
        }
        return true
    }

    @discardableResult
    public func repairError(_ ref: ErrorRef, as payload: String) -> EntryEdit {
        guard accepts(.errors), canRepair(ref), let old = book.part(ref.owner),
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

    /// Whether a review's scene keeps the copy's text through an Errors-tab change: a fixed
    /// comment entry may put a comment on it, nothing more (ADR 0042). A book's may change.
    private func keepsTheCopysText(from old: BookPart?, to new: BookPart) -> Bool {
        guard case .review = document, case .scene(let before)? = old, case .scene(let after) = new else {
            return true
        }
        return before.id == after.id && before.title == after.title && before.tags == after.tags
            && Self.changesOnlyComments(from: before.body, to: after.body)
    }

    /// Whether Fix applies to `ref`'s entry. A review's file has no place for a book's front
    /// matter or scene metadata, so there only a comment can be fixed (ADR 0042).
    public func canRepair(_ ref: ErrorRef) -> Bool {
        guard ref.entry.tag.isRepairable else { return false }
        switch document {
        case .book: return true
        case .review: return ref.entry.tag == .comments
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
        guard let driver = driver(for: .errors), old != part, keepsTheCopysText(from: old, to: part),
            book.replace(owner, with: part)
        else {
            return
        }
        if case .scene(let scene) = part {
            wordCounts.recount(scene)
            if case .scene(let before) = old {
                for part in TextPart.allCases where !part.historyAgrees(before, scene) {
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
            throw .fileSystem(FileSystemError(.write, document.url, .notFound))
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
            if let writer = writer.book { await recordPending(writer) }
            if !overwrittenRecords.isEmpty, !isDetached { store?.tellRecords(of: self) }
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
    func detach() -> DocumentWriter? {
        defer { access = .closed }
        if case .writable(_, let writer, _) = access { return writer } else { return nil }
    }

    /// Once the book is detached, the store has told its records as lost or carried them to the
    /// book read again, so a save still running then mustn't tell them again.
    private var isDetached: Bool {
        if case .closed = access { true } else { false }
    }
}

/// Names the scene of one structure change for its undo and redo, whatever its id becomes.
private struct StructureTarget: Hashable {
    let id = UUID()
}

/// What an edit changes, for what the open book lets the writer change (`OpenBook.accepts`).
public enum EditKind: Hashable, Sendable {
    /// The text and styles of the page, the scenes' titles and tags, and the scenes themselves.
    case manuscript
    /// Comments and notes.
    case annotations
    /// The Errors tab's entries.
    case errors
}

extension TextPart {
    var editKind: EditKind {
        switch self {
        case .body: .manuscript
        case .notes: .annotations
        }
    }
}

/// What the open book is, and where (ADR 0042).
public enum OpenDocument: Hashable, Sendable {
    case book(PackageLayout)
    case review(ReviewContext)

    public var kind: DocumentKind {
        switch self {
        case .book: .book
        case .review: .review
        }
    }

    /// What the writer chose to open: the package, or the review copy.
    public var url: URL {
        switch self {
        case .book(let layout): layout.root
        case .review(let context): context.copyFile
        }
    }
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
