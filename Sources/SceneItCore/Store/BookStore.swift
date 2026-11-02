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
    @ObservationIgnored private var operation = Operation.idle

    private enum Operation {
        case idle
        /// Callers waiting their turn, first come first served.
        case running(waiting: [CheckedContinuation<Void, Never>])
    }

    public init(
        clock: C, fileSystem: any FileSystem = LocalFileSystem(), mirror: BackupMirror,
        memory: any BookMemory,
        prompts: any StorePrompts
    ) {
        self.clock = clock
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
                return .success(try await Self.load(url, policy, fileSystem))
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
            switch await prompts.ask(LockWording.alert(for: reason)) {
            case .keepReadOnly:
                return .openedReadOnly(reason)
            case .openAnyway(let record):
                return await openExclusively(url, onLockRecord: .openAnyway(record))
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
            await book.close()
            return .stayed
        }
        await replaceCurrent(with: book)
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
                await openOtherVersion(of: book)
            }
        }
    }

    /// Saves my version as a new package, releases the original's lock, and reopens the
    /// original from disk. If the copy can't be saved, nothing changes and autosave stays paused.
    private func openOtherVersion(of book: OpenBook<C>) async {
        let original = book.layout.root
        let mine = book.book
        let copy: URL
        do throws(CopyError) {
            copy = try await BookWriter.saveCopy(
                mine, nextTo: original,
                named: { StoreWording.myEditsFileName(title: mine.title, original: original, attempt: $0) },
                fileSystem: fileSystem, mirror: mirror)
        } catch {
            await prompts.tell(StoreWording.copyFailed(error))
            return
        }
        Log.store.info("saved my version of a changed book as a separate book")
        remember(copy)
        current = nil
        await book.close()
        _ = await openExclusively(original, onLockRecord: .respect, myEditsSavedAs: copy)
    }

    // MARK: Closing and quitting

    /// Saves and closes the open book; `false` if the writer chose to keep it open.
    @discardableResult
    public func closeBook() async -> Bool {
        await exclusively {
            guard await settleCurrent(before: .closeBook) != .stay else { return false }
            await replaceCurrent(with: nil)
            return true
        }
    }

    /// The `applicationShouldTerminate` path: saves, asking the writer whenever quitting would
    /// lose edits, then releases the book. `false` means don't quit.
    public func prepareToQuit() async -> Bool {
        await exclusively {
            guard let book = current else { return true }
            switch await book.settle(before: .quit, asking: prompts) {
            case .stay:
                return false
            case .saved:
                current = nil
                await book.close()
                return true
            case .discarding:
                current = nil
                book.closeImmediately()
                return true
            }
        }
    }

    /// `applicationWillTerminate`: releases the book's lock now, unless a save is still running.
    public func closeForTermination() {
        current?.closeImmediately()
        current = nil
    }

    // MARK: Helpers

    private func settleCurrent(before leaving: Leaving) async -> OpenBook<C>.Settled {
        await current?.settle(before: leaving, asking: prompts) ?? .saved
    }

    private func replaceCurrent(with book: OpenBook<C>?) async {
        let old = current
        current = book
        await old?.close()
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
        _ url: URL, _ policy: LockRecordPolicy, _ fileSystem: any FileSystem
    ) async throws(LoadError) -> OpenedBook {
        try BookPackage.open(at: url, onLockRecord: policy, fileSystem: fileSystem)
    }

    @concurrent
    private nonisolated static func create(
        _ url: URL, title: String, _ fileSystem: any FileSystem
    ) async throws(CreateError) -> EditableBook {
        try BookPackage.create(at: url, title: title, fileSystem: fileSystem)
    }
}
