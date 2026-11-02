import Foundation
import Observation

/// Holds at most one open book (ADR 0021) and does everything that opens, creates, switches,
/// saves or closes it, asking the writer through `StorePrompts` where a choice is needed.
///
/// Its operations run one at a time: a second request (a book forwarded by another launch
/// while an alert is up, say) waits for the first to finish.
@MainActor
@Observable
public final class BookStore<C: Clock<Duration>> {
    public private(set) var current: OpenBook<C>?
    public private(set) var recentBooks: [URL]

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
        /// It's the book already open for editing.
        case alreadyOpen
        case failed(LoadError)
        /// The writer chose to stay in the current book.
        case stayed
    }

    public enum CreateOutcome: Hashable, Sendable {
        case created
        case failed(CreateError)
        case stayed
    }

    // MARK: Opening and creating

    /// Opens `url`, first saving and closing the current book. A book that won't load, or the
    /// writer choosing to stay, leaves the current book open and untouched.
    @discardableResult
    public func open(_ url: URL) async -> OpenOutcome {
        await exclusively { await openExclusively(url, onLockRecord: .respect) }
    }

    /// Books Finder or another launch asked for together. One book is open at a time
    /// (ADR 0021): the first is opened, and the rest go to Recent Books, which the writer is told.
    public func open(_ books: [URL]) async {
        guard let first = books.first else { return }
        await exclusively {
            let outcome = await openExclusively(first, onLockRecord: .respect)
            let others = Array(books.dropFirst())
            guard !others.isEmpty else { return }
            Log.store.info("asked to open several books; opened the first", ["count": .count(books.count)])
            let isOpen: Bool =
                switch outcome {
                case .opened, .openedReadOnly, .alreadyOpen: true
                case .failed, .stayed: false
                }
            for book in others.reversed() { remember(book) }
            if isOpen { remember(first) }
            await prompts.tell(
                StoreWording.oneBookAtATime(open: isOpen ? first : nil, addedToRecents: others))
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

    @discardableResult
    public func create(at url: URL) async -> CreateOutcome {
        await exclusively {
            let switched = await switchBooks(to: url) { () async -> Result<OpenedBook, CreateError> in
                do throws(CreateError) {
                    let title = url.deletingPathExtension().lastPathComponent
                    return .success(.editing(try await Self.create(url, title: title, fileSystem)))
                } catch {
                    return .failure(error)
                }
            }
            switch switched {
            case .switched: return .created
            case .stayed: return .stayed
            case .failed(let error):
                await prompts.tell(StoreWording.createFailed(error))
                return .failed(error)
            }
        }
    }

    private func openExclusively(
        _ url: URL, onLockRecord policy: LockRecordPolicy, myEditsSavedAs copy: URL? = nil
    ) async -> OpenOutcome {
        if let current, current.isEditable, current.layout.root.canonicalPath == url.canonicalPath {
            return .alreadyOpen
        }
        let switched = await switchBooks(to: url) { () async -> Result<OpenedBook, LoadError> in
            do throws(LoadError) {
                return .success(try await Self.load(url, policy, parseDefaults, fileSystem))
            } catch {
                return .failure(error)
            }
        }
        switch switched {
        case .stayed:
            return .stayed
        case .failed(let error):
            await prompts.tell(StoreWording.loadFailed(error, myEditsSavedAs: copy))
            forget(url)
            return .failed(error)
        case .switched(.editing):
            return .opened
        case .switched(.readOnly(_, let reason)):
            switch await prompts.ask(ReadOnlyWording.alert(for: reason)) {
            case .keepReadOnly:
                return .openedReadOnly(reason)
            case .openAnyway(let record):
                return await openExclusively(url, onLockRecord: .openAnyway(record))
            case .makeEditable:
                switch await makeEditableExclusively() {
                case .editable: return .opened
                case .readOnly(let reason): return .openedReadOnly(reason)
                case .failed, .notRepaired: return .openedReadOnly(reason)
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
    }

    /// Keeps the original of a book that opened read-only because it was repaired, then
    /// opens it for editing. The book's first save comes after the original is on disk.
    @discardableResult
    public func makeEditable() async -> MakeEditableOutcome {
        await exclusively { await makeEditableExclusively() }
    }

    private func makeEditableExclusively() async -> MakeEditableOutcome {
        guard let book = current, case .readOnly(.repairedOnOpen(let repair)) = book.status else {
            return .notRepaired
        }
        let kept: KeptOriginal
        do throws(FileSystemError) {
            kept = try await Self.keepOriginal(
                of: ReadOnlyBook(layout: book.layout, book: book.book), repair, fileSystem)
        } catch {
            await prompts.tell(ReadOnlyWording.makeEditableFailed(error))
            return .failed(error)
        }
        return await edit(book, keeping: kept, onLockRecord: .respect)
    }

    private func edit(
        _ book: OpenBook<C>, keeping kept: KeptOriginal, onLockRecord policy: LockRecordPolicy
    ) async -> MakeEditableOutcome {
        switch await Self.edit(kept, policy, fileSystem) {
        case .editing(let editable):
            let writer = BookWriter(editable.package, mirror: mirror)
            guard book === current else {
                await writer.release()
                return .notRepaired
            }
            book.becomeEditable(writer, clock: clock)
            return .editable
        case .readOnly(_, let reason):
            switch await prompts.ask(ReadOnlyWording.alert(for: reason)) {
            case .openAnyway(let record):
                return await edit(book, keeping: kept, onLockRecord: .openAnyway(record))
            case .keepReadOnly, .makeEditable:
                return .readOnly(reason)
            }
        }
    }

    private enum Switch<Failure: Error> {
        case switched(OpenedBook)
        case failed(Failure)
        case stayed
    }

    /// ADR 0021: saves the current book, gets the next one, then swaps them in the same
    /// main-actor turn as the last check that the current book's edits are all on disk. A next
    /// book that can't be had, or the writer choosing to stay, leaves the current one open.
    private func switchBooks<Failure>(
        to url: URL, obtaining next: () async -> Result<OpenedBook, Failure>
    ) async -> Switch<Failure> {
        var settled = await settleCurrent(before: .closeBook)
        guard settled != .stay else { return .stayed }
        let opened: OpenedBook
        switch await next() {
        case .success(let success): opened = success
        case .failure(let error): return .failed(error)
        }
        let book = OpenBook(opened, clock: clock, mirror: mirror, store: self)
        if settled == .saved { settled = await settleCurrent(before: .closeBook) }
        guard settled != .stay else {
            await book.detach()?.release()
            return .stayed
        }
        await replaceCurrent(with: book, after: settled)
        remember(url)
        return .switched(opened)
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
        current = nil
        Log.store.info("saved my version of a changed book as a separate book", ["passes": .count(pass)])
        let copyURL = copy.layout.root
        remember(copyURL)
        await copy.release()
        await writer?.release()
        if case .externallyModified(.notAFile) = error {
            forget(original)
            if case .opened = await openExclusively(copyURL, onLockRecord: .respect) {
                await prompts.tell(StoreWording.openedMyVersion(copyURL))
            }
        } else {
            _ = await openExclusively(original, onLockRecord: .respect, myEditsSavedAs: copyURL)
        }
    }

    // MARK: Closing and quitting

    public enum LeaveOutcome: Hashable, Sendable {
        /// The book was saved (or the writer chose to discard its edits) and closed.
        case left
        /// The writer chose to keep the book open.
        case stayed
    }

    /// Saves and closes the open book.
    @discardableResult
    public func closeBook() async -> LeaveOutcome {
        await exclusively {
            let settled = await settleCurrent(before: .closeBook)
            guard settled != .stay else { return .stayed }
            await replaceCurrent(with: nil, after: settled)
            return .left
        }
    }

    /// The `applicationShouldTerminate` path: saves, asking the writer whenever quitting would
    /// lose edits, then releases the book.
    public func prepareToQuit() async -> LeaveOutcome {
        await exclusively {
            guard let book = current else { return .left }
            switch await book.settle(before: .quit, asking: prompts) {
            case .stay:
                return .stayed
            case .saved:
                let writer = book.detach()
                current = nil
                await writer?.release()
                return .left
            case .discarding:
                let writer = book.detach()
                current = nil
                writer?.releaseUnlessSaving()
                return .left
            }
        }
    }

    /// `applicationWillTerminate`: releases the book's lock now, unless a save is still running.
    public func closeForTermination() {
        current?.detach()?.releaseUnlessSaving()
        current = nil
    }

    // MARK: Helpers

    private func settleCurrent(before leaving: Leaving) async -> OpenBook<C>.Settled {
        await current?.settle(before: leaving, asking: prompts) ?? .saved
    }

    /// The old book is detached in this turn, so it refuses edits before anything else runs.
    /// After the writer chose to discard edits, a save may be stuck, so its release isn't
    /// awaited: waiting here would hold every later operation, quitting included.
    private func replaceCurrent(with book: OpenBook<C>?, after settled: OpenBook<C>.Settled) async {
        let old = current?.detach()
        current = book
        switch settled {
        case .discarding:
            if let old { Task { await old.release() } }
        case .saved, .stay:
            await old?.release()
        }
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

    @concurrent
    private nonisolated static func load(
        _ url: URL, _ policy: LockRecordPolicy, _ defaults: ParseDefaults, _ fileSystem: any FileSystem
    ) async throws(LoadError) -> OpenedBook {
        try BookPackage.open(at: url, onLockRecord: policy, defaults: defaults, fileSystem: fileSystem)
    }

    @concurrent
    private nonisolated static func keepOriginal(
        of book: ReadOnlyBook, _ repair: Repair, _ fileSystem: any FileSystem
    ) async throws(FileSystemError) -> KeptOriginal {
        try BookPackage.keepOriginal(of: book, repair, fileSystem: fileSystem)
    }

    @concurrent
    private nonisolated static func edit(
        _ kept: KeptOriginal, _ policy: LockRecordPolicy, _ fileSystem: any FileSystem
    ) async -> OpenedBook {
        BookPackage.edit(kept, onLockRecord: policy, fileSystem: fileSystem)
    }

    @concurrent
    private nonisolated static func create(
        _ url: URL, title: String, _ fileSystem: any FileSystem
    ) async throws(CreateError) -> EditableBook {
        try BookPackage.create(at: url, title: title, fileSystem: fileSystem)
    }
}
