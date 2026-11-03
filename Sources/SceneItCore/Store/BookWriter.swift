import Foundation
import Synchronization

/// What one save did, for the status bar.
public enum WriteResult: Hashable, Sendable {
    /// `book.md` already held exactly this book.
    case unchanged
    case saved(SavedBackups)
}

/// What a save that wrote `book.md` did for its backups: the rotation (`bak1…3`) and the
/// tiered snapshots (ADR 0005, 0019).
public struct SavedBackups: Hashable, Sendable {
    public let rotation: BackupStatus
    public let snapshots: SnapshotReport

    public init(rotation: BackupStatus, snapshots: SnapshotReport) {
        self.rotation = rotation
        self.snapshots = snapshots
    }

    public var areWorking: Bool {
        rotation == .intact && snapshots.failures.isEmpty
    }
}

/// An editable book's package and backup keeper. Everything it does runs off the main actor:
/// a save can flush files to the drive, and releasing the package clears its lock record
/// (ADR 0020). Its mutex serializes one book's saves, snapshots and release.
final class BookWriter: Sendable {
    private struct Held: Sendable {
        let package: BookPackage
        let keeper: BackupKeeper
    }

    let layout: PackageLayout
    private let fileSystem: any FileSystem
    private let held: Mutex<Held?>

    init(_ package: BookPackage, mirror: BackupMirror) {
        layout = package.layout
        fileSystem = package.fileSystem
        held = Mutex(Held(package: package, keeper: BackupKeeper(package: package, mirror: mirror)))
    }

    @concurrent
    func save(_ book: Book, onExternalChange policy: ExternalChangePolicy) async throws(SaveError)
        -> WriteResult
    {
        try held.withLock { (held) throws(SaveError) -> WriteResult in
            guard let held else { throw .fileSystem(FileSystemError(.write, layout.book, .notFound)) }
            return try Self.write(book, policy, held.package, held.keeper)
        }
    }

    /// `BookPackage.fileCopy`, snapshotting the book if its save wrote it.
    @concurrent
    func fileCopy(of book: Book, as record: FilingRecord) async throws(FilingFailure) -> FilingOutcome {
        try held.withLock { (held) throws(FilingFailure) -> FilingOutcome in
            guard let held else { throw .fileSystem(FileSystemError(.read, layout.book, .notFound)) }
            let filed = try held.package.fileCopy(of: book, as: record)
            if case .saved(_, let published) = filed.saved { _ = held.keeper.keep(published, now: .now) }
            return filed.outcome
        }
    }

    /// `Archive.reconcile`, after any running save or filing; `nil` once released.
    @concurrent
    func reconcileArchive(_ access: Archive.Access) async -> ReconciledArchive? {
        held.withLock { held in
            held.map {
                Archive(layout: $0.package.layout, fileSystem: $0.package.fileSystem).reconcile(access)
            }
        }
    }

    /// Waits for a running save, then drops the package, which releases the book's lock.
    @concurrent
    func release() async {
        let package = held.withLock { held in
            defer { held = nil }
            return held?.package
        }
        _ = consume package
    }

    /// For termination, where nothing may wait: if a save is still running, the package is
    /// left to the kernel, which drops the `flock` when the process exits.
    func releaseUnlessSaving() {
        let package = held.withLockIfAvailable { held in
            defer { held = nil }
            return held?.package
        }
        _ = consume package
    }

    /// A new, empty package next to `original`, named by `name(attempt)` with the first attempt
    /// whose name is free (ADR 0018's "Open Other Version"). `create` refusing an existing name
    /// is the collision check, so two copies can't race for one name.
    @concurrent
    static func createCopy(
        titled title: String, nextTo original: URL, named name: @Sendable (Int) -> String,
        fileSystem: any FileSystem, mirror: BackupMirror
    ) async throws(CreateError) -> BookWriter {
        let folder = original.deletingLastPathComponent()
        var attempt = 1
        while true {
            let url = folder.appending(path: name(attempt), directoryHint: .isDirectory)
            do {
                let created = try BookPackage.create(at: url, title: title, fileSystem: fileSystem)
                return BookWriter(created.package, mirror: mirror)
            } catch .alreadyExists(let url) {
                guard attempt < maximumCopyAttempts else { throw .alreadyExists(url) }
                attempt += 1
            }
        }
    }

    /// Releases a copy that never received its book and removes it, so no empty "(my edits)"
    /// book is left to be mistaken for the writer's version.
    /// A copy holding a filed copy isn't unfinished, and is left whole.
    @concurrent
    func discardCopy() async {
        await release()
        let archive = (try? fileSystem.contents(of: layout.archive)) ?? []
        guard ArchiveReconciliation.filedCopies(in: archive).isEmpty else {
            Log.store.error("an unfinished copy of a book holds a filed copy; left it in place")
            return
        }
        do {
            try Self.removeTree(layout.root, fileSystem)
        } catch {
            Log.store.error("couldn't remove an unfinished copy of a book", error.logMetadata)
        }
    }

    /// Removes `directory` and everything in it, never following a link out of it.
    private static func removeTree(_ directory: URL, _ fileSystem: any FileSystem) throws(FileSystemError) {
        for entry in try fileSystem.contents(of: directory) {
            let url = directory.appending(path: entry.name)
            if entry.kind == .directory {
                try removeTree(url, fileSystem)
            } else {
                try fileSystem.remove(url)
            }
        }
        try fileSystem.removeDirectory(directory)
    }

    private static let maximumCopyAttempts = 100

    private static func write(
        _ book: Book, _ policy: ExternalChangePolicy, _ package: BookPackage, _ keeper: BackupKeeper
    ) throws(SaveError) -> WriteResult {
        switch try package.save(book, onExternalChange: policy) {
        case .unchanged:
            return .unchanged
        case .saved(let rotation, let published):
            return .saved(SavedBackups(rotation: rotation, snapshots: keeper.keep(published, now: .now)))
        }
    }
}

public enum CopyError: Error, Hashable, Sendable {
    case create(CreateError)
    /// The copy's package was created, but saving into it failed; it was removed again.
    case save(SaveError)
}
