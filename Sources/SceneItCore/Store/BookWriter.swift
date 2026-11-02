import Foundation
import Synchronization

/// What one save did, for the status bar.
public enum WriteResult: Hashable, Sendable {
    /// `book.json` already held exactly this book.
    case unchanged
    case saved(SavedBackups)
}

/// What a save that wrote `book.json` did for its backups: the rotation (`bak1…3`) and the
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
    private let held: Mutex<Held?>

    init(_ package: BookPackage, mirror: BackupMirror) {
        layout = package.layout
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

    /// Saves `book` as a new package next to `original`, named by `name(attempt)` with the
    /// first attempt whose name is free (ADR 0018's "Open Other Version").
    @concurrent
    static func saveCopy(
        _ book: Book, nextTo original: URL, named name: @Sendable (Int) -> String, fileSystem: any FileSystem,
        mirror: BackupMirror
    ) async throws(CopyError) -> URL {
        let folder = original.deletingLastPathComponent()
        var attempt = 1
        while true {
            let url = folder.appending(path: name(attempt), directoryHint: .isDirectory)
            let created: EditableBook
            do {
                created = try BookPackage.create(at: url, title: book.title, fileSystem: fileSystem)
            } catch .alreadyExists(let url) {
                guard attempt < maximumCopyAttempts else { throw .create(.alreadyExists(url)) }
                attempt += 1
                continue
            } catch {
                throw .create(error)
            }
            let keeper = BackupKeeper(package: created.package, mirror: mirror)
            do {
                _ = try write(book, .refuse, created.package, keeper)
            } catch {
                throw .save(url, error)
            }
            return url
        }
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
    /// The copy's package was created at this URL, holding an empty book, but saving into it failed.
    case save(URL, SaveError)
}
