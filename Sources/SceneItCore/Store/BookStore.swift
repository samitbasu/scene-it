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
    @ObservationIgnored private let memory: any BookMemory
    @ObservationIgnored private let prompts: any StorePrompts
    @ObservationIgnored private let parseDefaults: ParseDefaults
    @ObservationIgnored private var operation = Operation.idle

    private enum Operation {
        case idle
        /// Callers waiting their turn, first come first served.
        case running(waiting: [CheckedContinuation<Void, Never>])
    }

    public init(
        clock: C, fileSystem: any FileSystem = LocalFileSystem(), mirror: BackupMirror,
        memory: any BookMemory, prompts: any StorePrompts, parseDefaults: ParseDefaults = .system
    ) {
        self.clock = clock
        self.parseDefaults = parseDefaults
        self.fileSystem = fileSystem
        self.mirror = mirror
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
                case .failed, .refused: false
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
            let own = book.layout.root.canonicalPath
            let others = books.filter { $0.canonicalPath != own }
            guard !others.isEmpty else { return .alreadyOpen }
            Log.store.info("refused other books while one is open", ["count": .count(others.count)])
            await prompts.tell(OneBookWording.refusal(of: others, whileOpen: book.layout.root))
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

    /// Creates a book from the start state; refused while a book is open (ADR 0038).
    @discardableResult
    public func create(at url: URL) async -> CreateOutcome {
        await exclusively {
            if let book = current {
                Log.store.info("refused to create a book while one is open")
                await prompts.tell(OneBookWording.createRefusal(of: url, whileOpen: book.layout.root))
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
            case .again(let book): book.layout.root
            }
        }
    }

    /// A book that won't load is told and forgotten only when it was chosen; a replacement
    /// that won't load is the caller's to tell, and stays in Recent Books.
    private func load(_ target: Target, onLockRecord policy: LockRecordPolicy) async -> OpenOutcome {
        let loaded: LoadedBook
        do throws(LoadError) {
            loaded = try await Self.load(target.url, policy, parseDefaults, fileSystem)
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
        let kept: KeptOriginal
        do throws(FileSystemError) {
            kept = try await Self.keepOriginal(of: repair, fileSystem)
        } catch {
            await prompts.tell(ReadOnlyWording.makeEditableFailed(error))
            return .failed(error)
        }
        return await edit(book, keeping: kept, onLockRecord: .respect)
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
            book.becomeEditable(writer, clock: clock)
            if let reconciled = await writer.reconcileArchive(.writable) { book.show(reconciled) }
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
    /// so it refuses edits before anything else runs.
    @discardableResult
    private func install(_ loaded: LoadedBook, as target: Target) async -> OpenBook<C> {
        let book = OpenBook(loaded.opened, archive: loaded.archive, clock: clock, mirror: mirror, store: self)
        let replaced: BookWriter?
        switch target {
        case .chosen:
            precondition(isChoosing, "one book at a time, chosen from the start state (ADR 0038)")
            replaced = nil
        case .again(let old), .myVersion(_, replacing: let old):
            precondition(old === current, "only the open book is replaced")
            replaced = old.detach()
        }
        session = .open(book)
        remember(target.url)
        await replaced?.release()
        return book
    }

    // MARK: Filing a copy (PLAN §7.1)

    /// The dialog's File copy: saves the book, files a copy with `record`, and tells the writer
    /// about anything that went wrong. A copy that was filed but couldn't be locked or indexed
    /// is still `.filed`.
    @discardableResult
    public func fileACopy(as record: FilingRecord) async -> FilingResult {
        await exclusively {
            let result = await current?.fileCopy(as: record) ?? .unavailable
            if let notice = ArchiveWording.notice(for: result, record: record) { await prompts.tell(notice) }
            return result
        }
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
            let name = StoreWording.myEditsFileName(
                title: book.book.title, original: book.layout.root, attempt: 1)
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
        let original = book.layout.root
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
        await writer?.release()
        let reopened: OpenOutcome
        if case .externallyModified(.notAFile) = error {
            forget(original)
            reopened = await load(.myVersion(copyURL, replacing: book), onLockRecord: .respect)
            if case .opened = reopened { await prompts.tell(StoreWording.openedMyVersion(copyURL)) }
        } else {
            reopened = await load(.again(book), onLockRecord: .respect)
        }
        guard case .failed(let failure) = reopened else { return }
        session = .choosing
        await prompts.tell(OneBookWording.bookLost(failure, myVersion: copyURL))
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
            await writer?.release()
        }
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

        init(_ opened: OpenedBook, _ fileSystem: any FileSystem) {
            self.opened = opened
            archive =
                switch opened {
                case .editing(let editable): editable.package.reconcileArchive()
                case .readOnly(let readOnly, _): readOnly.reconcileArchive(fileSystem: fileSystem)
                }
        }
    }

    @concurrent
    private nonisolated static func load(
        _ url: URL, _ policy: LockRecordPolicy, _ defaults: ParseDefaults, _ fileSystem: any FileSystem
    ) async throws(LoadError) -> LoadedBook {
        LoadedBook(
            try BookPackage.open(at: url, onLockRecord: policy, defaults: defaults, fileSystem: fileSystem),
            fileSystem)
    }

    @concurrent
    private nonisolated static func keepOriginal(
        of repair: Repair, _ fileSystem: any FileSystem
    ) async throws(FileSystemError) -> KeptOriginal {
        try BookPackage.keepOriginal(of: repair, fileSystem: fileSystem)
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
