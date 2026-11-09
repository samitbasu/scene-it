import Foundation
import Observation

/// Holds the process's one open book (ADR 0038) and does everything that opens, creates, saves
/// or closes it, asking the writer through `StorePrompts` where a choice is needed.
///
/// Its operations run one at a time: a second request (a book forwarded by another launch
/// while an alert is up, say) waits for the first to finish.
@MainActor
@Observable
public final class BookStore<C: Clock<Duration>> {
    public private(set) var session = Session.choosing
    public private(set) var recentBooks: [URL]

    /// One book at a time, never switched in place (ADR 0038): a book is chosen from the start
    /// state, and closing it goes back there. While a book is open, it's replaced only by itself
    /// read again (Open Anyway, Open Other Version) or, when its original can't be read, by the
    /// writer's own version of it (ADR 0018).
    public enum Session {
        /// The start state, the only one a book can be opened or created from.
        case choosing
        case open(OpenBook<C>)
        /// Close Book is saving the book or asking about it. The book is still open (Cancel
        /// returns to `open`), but another close isn't.
        case closing(OpenBook<C>)
    }

    public var current: OpenBook<C>? {
        switch session {
        case .choosing: nil
        case .open(let book), .closing(let book): book
        }
    }

    /// The book while it's open and not being closed: what File a Copy and Make Editable act on.
    public var openBook: OpenBook<C>? {
        if case .open(let book) = session { book } else { nil }
    }

    /// The book File a Copy can start on: a book, not a review, open for editing, and not
    /// being closed.
    public var fileableBook: OpenBook<C>? {
        openBook.flatMap { $0.isEditable && $0.document.kind == .book ? $0 : nil }
    }

    /// Make Editable… applies: the open book, not being closed, was repaired as it opened.
    public var canMakeEditable: Bool {
        openBook?.canBeMadeEditable == true
    }

    /// New Book, Open Book and the start state's recent books are offered only here.
    public var isChoosing: Bool {
        if case .choosing = session { true } else { false }
    }

    /// An operation is running. Nothing the store hands control to (the app's quit) may run
    /// while this holds: it couldn't start one of its own until it ended.
    public var isBusy: Bool {
        if case .running = operation { true } else { false }
    }

    @ObservationIgnored private let clock: C
    @ObservationIgnored private let fileSystem: any FileSystem
    @ObservationIgnored private let mirror: BackupMirror
    @ObservationIgnored private let reviews: ReviewsFolder
    @ObservationIgnored private let memory: any BookMemory
    @ObservationIgnored private let prompts: any StorePrompts
    @ObservationIgnored private let parseDefaults: ParseDefaults
    @ObservationIgnored private var operation = Operation.idle

    private enum Operation {
        case idle
        /// Callers waiting their turn, first come first served.
        case running(waiting: [CheckedContinuation<Void, Never>])
    }

    /// `reviews` is where reviews keep their backups, kept originals and locks (review format §9 Q9).
    public init(
        clock: C, fileSystem: any FileSystem = LocalFileSystem(), mirror: BackupMirror,
        reviews: ReviewsFolder,
        memory: any BookMemory, prompts: any StorePrompts, parseDefaults: ParseDefaults = .system
    ) {
        self.clock = clock
        self.parseDefaults = parseDefaults
        self.fileSystem = fileSystem
        self.mirror = mirror
        self.reviews = reviews
        self.memory = memory
        self.prompts = prompts
        recentBooks = Self.urls(memory.recentBookPaths)
    }

    public enum OpenOutcome: Hashable, Sendable {
        case opened
        case openedReadOnly(ReadOnlyReason)
        /// It's this process's book already.
        case alreadyOpen
        case failed(LoadError)
        /// Review Book… couldn't open the file; the writer was told.
        case reviewFailed(ReviewOpenError)
        /// Another book is open (ADR 0038); the writer was told.
        case refused
    }

    public enum CreateOutcome: Hashable, Sendable {
        case created
        case failed(CreateError)
        /// A book is open (ADR 0038); the writer was told.
        case refused
    }

    // MARK: Opening and creating

    /// Opens `url` from the start state. While a book is open, any other is refused, and the
    /// writer is told why (ADR 0038).
    @discardableResult
    public func open(_ url: URL) async -> OpenOutcome {
        await exclusively {
            if let refusal = await refusal(of: [url]) { return refusal }
            return await load(.chosen(url), onLockRecord: .respect)
        }
    }

    /// Books Finder or another launch asked for together. One book is open at a time
    /// (ADR 0038): the first is opened, and the rest go to Recent Books, which the writer is told.
    @discardableResult
    public func open(_ books: [URL]) async -> OpenOutcome? {
        guard let first = books.first else { return nil }
        return await exclusively {
            if let refusal = await refusal(of: books) { return refusal }
            let outcome = await load(.chosen(first), onLockRecord: .respect)
            let others = Array(books.dropFirst())
            guard !others.isEmpty else { return outcome }
            Log.store.info("asked to open several books; opened the first", ["count": .count(books.count)])
            let isOpen: Bool =
                switch outcome {
                case .opened, .openedReadOnly, .alreadyOpen: true
                case .failed, .reviewFailed, .refused: false
                }
            for book in others.reversed() { remember(book) }
            if isOpen { remember(first) }
            await prompts.tell(
                OneBookWording.severalBooks(open: isOpen ? first : nil, addedToRecents: others))
            return outcome
        }
    }

    /// Nil in the start state. Asked again for the open book alone, the store does nothing;
    /// asked for any other, it tells the writer why not.
    private func refusal(of books: [URL]) async -> OpenOutcome? {
        switch session {
        case .choosing:
            return nil
        case .open(let book), .closing(let book):
            let own = book.document.url.canonicalPath
            let others = books.filter { $0.canonicalPath != own }
            guard !others.isEmpty else { return .alreadyOpen }
            Log.store.info("refused other books while one is open", ["count": .count(others.count)])
            await prompts.tell(OneBookWording.refusal(of: others, whileOpen: book.document.url))
            return .refused
        }
    }

    /// Opens the most recent book, if there is one and it still exists. One that fails to
    /// load is told once, then forgotten, so the next launch shows the start state.
    public func reopenLastBook() async {
        guard let last = recentBooks.first else { return }
        guard FileManager.default.fileExists(atPath: last.path(percentEncoded: false)) else {
            forget(last)
            return
        }
        await open(last)
    }

    /// Review Book… (ADR 0029, 0041): opens the review copy or review file at `url` from the start
    /// state, with the review that belongs to it, or a new one. The copy is never written. A
    /// review that opens read-only is told, as a book is.
    @discardableResult
    public func openReview(_ url: URL) async -> OpenOutcome {
        await exclusively {
            if let refusal = await refusal(of: [url]) { return refusal }
            let loaded: LoadedReview
            do throws(ReviewOpenError) {
                loaded = try await Self.loadReview(url, reviews, parseDefaults.openedNow(), fileSystem)
            } catch {
                await prompts.tell(ReviewWording.openFailed(error))
                return .reviewFailed(error)
            }
            precondition(isChoosing, "one book at a time, chosen from the start state (ADR 0038)")
            let book = OpenBook(loaded, clock: clock, store: self)
            session = .open(book)
            if let other = loaded.otherReview {
                await prompts.tell(ReviewWording.otherReviewKept(other))
            }
            guard case .readOnly(let reason) = loaded.access else { return .opened }
            switch await prompts.ask(ReadOnlyWording.alert(for: reason, of: .review)) {
            case .keepReadOnly, .openAnyway:
                return .openedReadOnly(reason)
            case .makeEditable:
                switch await makeEditableExclusively() {
                case .editable: return .opened
                case .readOnly(let reason): return .openedReadOnly(reason)
                case .failed, .notRepaired, .keptReadOnly: return .openedReadOnly(reason)
                }
            }
        }
    }

    /// Creates a book from the start state; refused while a book is open (ADR 0038).
    @discardableResult
    public func create(at url: URL) async -> CreateOutcome {
        await exclusively {
            if let book = current {
                Log.store.info("refused to create a book while one is open")
                await prompts.tell(OneBookWording.createRefusal(of: url, whileOpen: book.document.url))
                return .refused
            }
            let loaded: LoadedBook
            do throws(CreateError) {
                loaded = try await Self.create(
                    url, title: url.deletingPathExtension().lastPathComponent, fileSystem)
            } catch {
                await prompts.tell(StoreWording.createFailed(error))
                return .failed(error)
            }
            await install(loaded, as: .chosen(url))
            return .created
        }
    }

    /// What to read, and where it goes. Only the first book is chosen by path: every later one
    /// replaces the open book with itself read again, or (ADR 0018's Open My Version) with the
    /// writer's own copy of it.
    private enum Target {
        case chosen(URL)
        /// The open book's own package, read again (Open Anyway, Open Other Version).
        case again(OpenBook<C>)
        /// ADR 0018: the writer's copy, in place of an original that can't be read.
        case myVersion(URL, replacing: OpenBook<C>)

        var url: URL {
            switch self {
            case .chosen(let url), .myVersion(let url, _): url
            case .again(let book): book.document.url
            }
        }

        /// The records waiting for this package's index: a book read again keeps the old
        /// one's, which its reconciliation records. My version is another package, whose
        /// Archive has none of the original's copies.
        @MainActor var pending: Archive.Pending {
            if case .again(let book) = self { book.pendingRecords } else { [:] }
        }
    }

    /// A book that won't load is told and forgotten only when it was chosen; a replacement
    /// that won't load is the caller's to tell, and stays in Recent Books.
    private func load(_ target: Target, onLockRecord policy: LockRecordPolicy) async -> OpenOutcome {
        let loaded: LoadedBook
        do throws(LoadError) {
            loaded = try await Self.load(target.url, policy, target.pending, parseDefaults, fileSystem)
        } catch {
            if case .chosen(let url) = target {
                await prompts.tell(StoreWording.loadFailed(error))
                forget(url)
            }
            return .failed(error)
        }
        let book = await install(loaded, as: target)
        switch loaded.opened {
        case .editing:
            return .opened
        case .readOnly(_, let reason):
            switch await prompts.ask(ReadOnlyWording.alert(for: reason)) {
            case .keepReadOnly:
                return .openedReadOnly(reason)
            case .openAnyway(let record):
                let again = await load(.again(book), onLockRecord: .openAnyway(record))
                guard case .failed(let error) = again else { return again }
                await prompts.tell(StoreWording.loadFailed(error))
                return .openedReadOnly(reason)
            case .makeEditable:
                switch await makeEditableExclusively() {
                case .editable: return .opened
                case .readOnly(let reason): return .openedReadOnly(reason)
                case .failed, .notRepaired, .keptReadOnly: return .openedReadOnly(reason)
                }
            }
        }
    }

    // MARK: Make Editable (ADR 0024)

    public enum MakeEditableOutcome: Hashable, Sendable {
        case editable
        /// The original was kept, but the book couldn't be locked for editing.
        case readOnly(ReadOnlyReason)
        /// The original couldn't be kept, so nothing changed.
        case failed(FileSystemError)
        /// No book is open, or it isn't read-only because it was repaired as it opened.
        case notRepaired
        /// Asked to confirm, the writer chose Keep Read-Only.
        case keptReadOnly
    }

    /// Keeps the original of a book that opened read-only because it was repaired, then
    /// opens it for editing. The book's first save comes after the original is on disk.
    @discardableResult
    public func makeEditable() async -> MakeEditableOutcome {
        await exclusively { await makeEditableExclusively() }
    }

    /// Make Editable… from the banner or the File menu: asks first, with the open-time alert's
    /// message (Keep Read-Only is the default), then makes it editable if the writer chooses.
    @discardableResult
    public func confirmMakeEditable() async -> MakeEditableOutcome {
        await exclusively {
            guard let book = current, case .readOnly(.repairedOnOpen(let repair)) = book.status else {
                return .notRepaired
            }
            switch await prompts.ask(ReadOnlyWording.confirmMakeEditable(repair)) {
            case .makeEditable: return await makeEditableExclusively()
            case .keepReadOnly, .openAnyway: return .keptReadOnly
            }
        }
    }

    private func makeEditableExclusively() async -> MakeEditableOutcome {
        guard let book = current, case .readOnly(.repairedOnOpen(let repair)) = book.status else {
            return .notRepaired
        }
        do throws(FileSystemError) {
            switch (repair, book.document) {
            case (.book(let repair), .book):
                return await edit(
                    book, keeping: try await Self.keepOriginal(of: repair, fileSystem), onLockRecord: .respect
                )
            case (.review(let repair), .review(let context)):
                return await editReview(
                    book, context, keeping: try await Self.keepOriginal(of: repair, fileSystem))
            case (.book, .review), (.review, .book):
                return .notRepaired
            }
        } catch {
            await prompts.tell(ReadOnlyWording.makeEditableFailed(error, of: book.document.kind))
            return .failed(error)
        }
    }

    private func editReview(
        _ book: OpenBook<C>, _ context: ReviewContext, keeping kept: consuming KeptReviewOriginal
    ) async -> MakeEditableOutcome {
        let made = await Self.editReview(kept, context, fileSystem)
        switch consume made {
        case .editing(let file):
            let writer = ReviewWriter(file, context)
            guard book === current else {
                await writer.release()
                return .notRepaired
            }
            book.becomeEditable(.review(writer), clock: clock)
            return .editable
        case .readOnly(_, let reason):
            await prompts.tell(
                Notice(
                    title: ReadOnlyWording.readOnlyTitle,
                    message: ReadOnlyWording.readOnlyMessage(reason, of: .review)))
            return .readOnly(reason)
        }
    }

    private func edit(
        _ book: OpenBook<C>, keeping kept: consuming KeptOriginal, onLockRecord policy: LockRecordPolicy
    ) async -> MakeEditableOutcome {
        let made = await Self.edit(kept, policy, fileSystem)
        switch consume made {
        case .editing(let editable):
            let writer = BookWriter(editable.package, mirror: mirror)
            guard book === current else {
                await writer.release()
                return .notRepaired
            }
            book.becomeEditable(.book(writer), clock: clock)
            await book.reconcileArchive(with: writer)
            await tellRecords(book.takeRecordsToTell(.kept), in: book)
            return .editable
        case .readOnly(let kept, let reason):
            switch await prompts.ask(ReadOnlyWording.alert(for: reason)) {
            case .openAnyway(let record):
                return await edit(book, keeping: kept, onLockRecord: .openAnyway(record))
            case .keepReadOnly, .makeEditable:
                return .readOnly(reason)
            }
        }
    }

    /// The only way a book becomes the session's. A replaced book is detached in this turn,
    /// so it refuses edits before anything else runs. File a Copy's dialog stays up across the
    /// replacement, holding what was typed in it, and a book read again keeps the records its
    /// reconciliation couldn't save.
    @discardableResult
    private func install(_ loaded: LoadedBook, as target: Target) async -> OpenBook<C> {
        let book = OpenBook(
            loaded.opened, identity: loaded.identity, archive: loaded.archive, pending: target.pending,
            clock: clock, mirror: mirror,
            store: self)
        let replaced: DocumentWriter?
        switch target {
        case .chosen:
            precondition(isChoosing, "one book at a time, chosen from the start state (ADR 0038)")
            replaced = nil
        case .again(let old), .myVersion(_, replacing: let old):
            precondition(old === current, "only the open book is replaced")
            book.filingDraft = old.filingDraft
            replaced = old.detach()
        }
        session = .open(book)
        remember(target.url)
        await replaced?.release()
        await tellRecords(book.takeRecordsToTell(.kept), in: book)
        return book
    }

    // MARK: Filing a copy (PLAN §7.1)

    /// The dialog's File copy: saves the book, files a copy with `record`, and tells the writer
    /// about anything that went wrong. A copy that was filed but couldn't be locked or indexed
    /// is still `.filed`.
    ///
    /// Only `book` is filed. A book read again in its place since (a filing queued behind Open
    /// Other Version) files nothing and tells nothing: the new book's dialog holds the same draft,
    /// for the writer to file deliberately.
    @discardableResult
    public func fileACopy(of book: OpenBook<C>, as record: FilingRecord) async -> FilingResult {
        await exclusively {
            if let current, current !== book { return .unavailable }
            let result = current == nil ? .unavailable : await book.fileCopy(as: record)
            if let notice = ArchiveWording.notice(for: result, record: record) { await prompts.tell(notice) }
            await tellRecords(book.takeRecordsToTell(.kept), in: book)
            return result
        }
    }

    /// Export as SceneIt… (ADR 0029): the chosen story scenes of the book as it is now, saved or
    /// not, written as a review copy to `destination`. The book's own files are never touched,
    /// and the writer is told when nothing was written. Works on a read-only book too.
    public func exportReviewCopy(
        of book: OpenBook<C>, chosen: Set<SceneID>, to destination: URL, export: ExportID,
        exported: Timestamp
    ) async -> ExportResult {
        await exclusively {
            guard book === current, case .book(let layout) = book.document else {
                await prompts.tell(ExportWording.bookClosed)
                return .unavailable
            }
            let copy = ReviewCopy(projecting: book.book, chosen: chosen, export: export, exported: exported)
            do throws(ExportFailure) {
                try await Self.write(
                    copy, to: destination, outside: layout, identifiedAs: book.packageIdentity,
                    fileSystem)
                return .exported
            } catch {
                await prompts.tell(ExportWording.notice(for: error))
                return .failed(error)
            }
        }
    }

    @concurrent
    private nonisolated static func write(
        _ copy: ReviewCopy, to destination: URL, outside book: PackageLayout,
        identifiedAs identity: MountedIdentity?,
        _ fileSystem: any FileSystem
    ) async throws(ExportFailure) {
        try ReviewCopyWriter.write(
            copy, to: destination, outside: book, identifiedAs: identity, fileSystem: fileSystem)
    }

    // MARK: Saving

    /// Cmd+S. While autosave is paused on an external change, asks about it again instead.
    public func saveNow() {
        guard let current else { return }
        if case .paused = current.autosave?.state {
            Task { await askAboutExternalChange(in: current) }
        } else {
            current.saveNow()
        }
    }

    public func appDeactivated() {
        current?.appDeactivated()
    }

    func bookSaved(at date: Date) {
        memory.lastSaved = date
    }

    // MARK: Changed on disk (ADR 0018)

    func askAboutExternalChange(in book: OpenBook<C>) async {
        await exclusively {
            guard book === current, case .paused(let paused) = book.autosave?.state else { return }
            guard case .book(let layout) = book.document else {
                switch await prompts.ask(ReviewWording.externalChangeAlert(paused.error)) {
                case .keepMyVersion, .openOtherVersion: book.keepMyVersion()
                }
                return
            }
            let name = StoreWording.myEditsFileName(
                title: book.book.title, original: layout.root, attempt: 1)
            let alert = StoreWording.externalChangeAlert(paused.error, myEditsName: name)
            switch await prompts.ask(alert) {
            case .keepMyVersion:
                book.keepMyVersion()
            case .openOtherVersion:
                await openOtherVersion(of: book, after: paused.error)
            }
        }
    }

    /// How many times the copy is saved while the writer keeps typing; the last pass refuses edits.
    static var copyPasses: Int { 5 }

    /// Saves my version as a new package, then releases the original's lock and reopens the
    /// original from disk, or, when the original can't be read (`.notAFile`), opens the copy.
    /// If the copy can't be saved, it's removed, nothing else changes, and autosave stays paused.
    /// If what's opened in its place won't load, the start state shows, and my version stays
    /// first in Recent Books.
    ///
    /// Typing continues while the copy is written, so the copy is saved again until it holds
    /// exactly the open book, and the book is closed in the same main-actor turn as that check.
    private func openOtherVersion(of book: OpenBook<C>, after error: SaveError) async {
        guard case .book(let layout) = book.document else { return }
        let original = layout.root
        let title = book.book.title
        let copy: BookWriter
        do throws(CreateError) {
            copy = try await BookWriter.createCopy(
                titled: title, nextTo: original,
                named: { StoreWording.myEditsFileName(title: title, original: original, attempt: $0) },
                fileSystem: fileSystem, mirror: mirror)
        } catch {
            await prompts.tell(StoreWording.copyFailed(.create(error)))
            return
        }
        var pass = 1
        while true {
            if pass == Self.copyPasses { book.setEdits(.refused) }
            let mine = book.book
            do throws(SaveError) {
                _ = try await copy.save(mine, onExternalChange: .refuse)
            } catch {
                book.setEdits(.accepted)
                await copy.discardCopy()
                await prompts.tell(StoreWording.copyFailed(.save(error)))
                return
            }
            if book.book == mine { break }
            pass += 1
        }
        let writer = book.detach()
        Log.store.info("saved my version of a changed book as a separate book", ["passes": .count(pass)])
        let copyURL = copy.layout.root
        remember(copyURL)
        await copy.release()
        if let writer = writer?.book { await book.recordPending(writer) }
        await writer?.release()
        let reopened: OpenOutcome
        let replacement: Target
        if case .externallyModified(.notAFile) = error {
            forget(original)
            replacement = .myVersion(copyURL, replacing: book)
            reopened = await load(replacement, onLockRecord: .respect)
            if case .opened = reopened { await prompts.tell(StoreWording.openedMyVersion(copyURL)) }
        } else {
            replacement = .again(book)
            reopened = await load(replacement, onLockRecord: .respect)
        }
        if case .failed(let failure) = reopened {
            session = .choosing
            await prompts.tell(OneBookWording.bookLost(failure, myVersion: copyURL))
        }
        let readAgainHoldsTheRecords = if case .again = replacement, current != nil { true } else { false }
        await tellRecords(book.takeRecordsToTell(readAgainHoldsTheRecords ? .kept : .lost), in: book)
    }

    // MARK: Closing and quitting

    public enum LeaveOutcome: Hashable, Sendable {
        /// The book was saved (or the writer chose to discard its edits) and closed.
        case left
        /// The writer chose to keep the book open.
        case stayed
    }

    /// Close Book (ADR 0038): saves, asking the writer whenever closing would lose edits, then
    /// releases the book and returns to the start state.
    @discardableResult
    public func closeBook() async -> LeaveOutcome {
        await exclusively { await leave(.closeBook) }
    }

    /// The `applicationShouldTerminate` path: saves, asking the writer whenever quitting would
    /// lose edits, then releases the book.
    public func prepareToQuit() async -> LeaveOutcome {
        await exclusively { await leave(.quit) }
    }

    /// The book is detached in the same turn as the session changes, so it refuses edits from
    /// then on. After the writer chose to discard edits, a save may be stuck: closing releases
    /// the lock once that save ends, without holding later operations; quitting leaves the
    /// lock to the process exit if a save is still running.
    private func leave(_ leaving: Leaving) async -> LeaveOutcome {
        guard let book = current else { return .left }
        if leaving == .closeBook { session = .closing(book) }
        guard let departure = await departure(of: book, leaving) else {
            session = .open(book)
            return .stayed
        }
        let writer = book.detach()
        session = .choosing
        switch (departure, leaving) {
        case (.discarding, .closeBook):
            if let writer { Task { await writer.release() } }
        case (.discarding, .quit):
            writer?.releaseUnlessSaving()
        case (.saved, _):
            if let writer = writer?.book { await book.recordPending(writer) }
            await writer?.release()
        }
        // Told as lost even if a stuck save later records them; a false alarm is the safe direction.
        await tellRecords(book.takeRecordsToTell(.lost), in: book)
        return .left
    }

    /// How a leave that goes ahead left the book's edits.
    private enum Departure {
        case saved
        case discarding
    }

    /// Nil if the writer chose to stay.
    private func departure(of book: OpenBook<C>, _ leaving: Leaving) async -> Departure? {
        guard await book.confirmLeaving(leaving, asking: prompts) == .leave else { return nil }
        switch await book.settle(before: leaving, asking: prompts) {
        case .stay: return nil
        case .saved: return .saved
        case .discarding: return .discarding
        }
    }

    /// `applicationWillTerminate`: releases the book's lock now, unless a save is still running.
    public func closeForTermination() {
        current?.detach()?.releaseUnlessSaving()
        session = .choosing
    }

    // MARK: Helpers

    /// Tells the writer of `records`, which `book`'s index won't hold.
    private func tellRecords(_ records: UnrecordedCopies, in book: OpenBook<C>) async {
        guard case .book(let layout) = book.document else { return }
        let archive = Archive(layout: layout, fileSystem: fileSystem)
        guard
            let notice = ArchiveWording.unrecorded(
                records, listedOn: archive.modifiedDay, in: layout.root)
        else { return }
        await prompts.tell(notice)
    }

    /// For a save, which no operation of the store's runs: tells `book`'s records once the
    /// running operation, if any, ends. One that leaves the book takes them first.
    func tellRecords(of book: OpenBook<C>) {
        Task { await exclusively { await tellRecords(book.takeRecordsToTell(.kept), in: book) } }
    }

    private func remember(_ book: URL) {
        updateRecentBooks { RecentBooks.remembering(book, in: $0) }
    }

    private func forget(_ book: URL) {
        updateRecentBooks { RecentBooks.forgetting(book, in: $0) }
    }

    private func updateRecentBooks(_ change: ([String]) -> [String]) {
        memory.recentBookPaths = change(memory.recentBookPaths)
        recentBooks = Self.urls(memory.recentBookPaths)
    }

    private static func urls(_ paths: [String]) -> [URL] {
        paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    private func exclusively<T>(_ body: () async -> T) async -> T {
        switch operation {
        case .idle:
            operation = .running(waiting: [])
        case .running(let waiting):
            await withCheckedContinuation { operation = .running(waiting: waiting + [$0]) }
        }
        defer {
            if case .running(var waiting) = operation, !waiting.isEmpty {
                let next = waiting.removeFirst()
                operation = .running(waiting: waiting)
                next.resume()
            } else {
                operation = .idle
            }
        }
        return await body()
    }

    /// A book as it opened, and its archive reconciled (PLAN §5.5): saved if the book is
    /// editable, only read if not.
    private struct LoadedBook: Sendable {
        let opened: OpenedBook
        let archive: ReconciledArchive
        /// The package's, as it opened; `nil` if it couldn't be identified.
        let identity: MountedIdentity?

        init(_ opened: OpenedBook, pending: Archive.Pending = [:], _ fileSystem: any FileSystem) {
            self.opened = opened
            identity = try? fileSystem.mountedIdentity(of: opened.layout.root)
            archive =
                switch opened {
                case .editing(let editable): editable.package.reconcileArchive(pending: pending)
                case .readOnly(let readOnly, _):
                    readOnly.reconcileArchive(pending: pending, fileSystem: fileSystem)
                }
        }
    }

    @concurrent
    private nonisolated static func load(
        _ url: URL, _ policy: LockRecordPolicy, _ pending: Archive.Pending, _ defaults: ParseDefaults,
        _ fileSystem: any FileSystem
    ) async throws(LoadError) -> LoadedBook {
        LoadedBook(
            try BookPackage.open(at: url, onLockRecord: policy, defaults: defaults, fileSystem: fileSystem),
            pending: pending, fileSystem)
    }

    @concurrent
    private nonisolated static func keepOriginal(
        of repair: BookRepair, _ fileSystem: any FileSystem
    ) async throws(FileSystemError) -> KeptOriginal {
        try BookPackage.keepOriginal(of: repair, fileSystem: fileSystem)
    }

    @concurrent
    private nonisolated static func keepOriginal(
        of repair: ReviewRepair, _ fileSystem: any FileSystem
    ) async throws(FileSystemError) -> KeptReviewOriginal {
        try ReviewFile.keepOriginal(of: repair, fileSystem: fileSystem)
    }

    @concurrent
    private nonisolated static func editReview(
        _ kept: consuming KeptReviewOriginal, _ context: ReviewContext, _ fileSystem: any FileSystem
    ) async -> ReviewFile.MadeEditable {
        ReviewFile.edit(kept, context, fileSystem: fileSystem)
    }

    @concurrent
    private nonisolated static func loadReview(
        _ url: URL, _ reviews: ReviewsFolder, _ opened: Timestamp, _ fileSystem: any FileSystem
    ) async throws(ReviewOpenError) -> LoadedReview {
        try ReviewFile.open(
            url, reviews: reviews, opened: opened, freshID: freshReviewID, fileSystem: fileSystem)
    }

    private nonisolated static func freshReviewID() -> ReviewID {
        var ids = IDGenerator.system
        return ids.reviewID()
    }

    @concurrent
    private nonisolated static func edit(
        _ kept: consuming KeptOriginal, _ policy: LockRecordPolicy, _ fileSystem: any FileSystem
    ) async -> MadeEditable {
        BookPackage.edit(kept, onLockRecord: policy, fileSystem: fileSystem)
    }

    @concurrent
    private nonisolated static func create(
        _ url: URL, title: String, _ fileSystem: any FileSystem
    ) async throws(CreateError) -> LoadedBook {
        LoadedBook(
            .editing(try BookPackage.create(at: url, title: title, fileSystem: fileSystem)), fileSystem)
    }
}
