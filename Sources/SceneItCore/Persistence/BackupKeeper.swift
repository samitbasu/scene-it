import Foundation

/// Takes the tiered snapshots of ADR 0005 after a save: one copy of `book.json` in the
/// package's `Backups/`, and one in the external mirror's folder for this book.
///
/// It never throws and never touches `book.json`: every failure is logged and returned in
/// the `SnapshotReport` (ADR 0019).
public struct BackupKeeper: Sendable {
    private let layout: PackageLayout
    private let mirror: BackupMirror
    private let fileSystem: any FileSystem

    public init(package: BookPackage, mirror: BackupMirror) {
        layout = package.layout
        self.mirror = mirror
        fileSystem = package.fileSystem
    }

    /// Call from `BookPackage.save`'s `afterPublishing`. Each destination decides on its own
    /// whether a snapshot is due, and prunes its own snapshots before writing one.
    public func keep(_ book: PublishedBook, now: Date) -> SnapshotReport {
        let inPackage = keep(book, in: { () throws(SnapshotFailure) in layout.snapshots }, now: now, .package)
        let inMirror = keep(book, in: mirrorFolder, now: now, .mirror)
        return SnapshotReport(package: inPackage, mirror: inMirror)
    }

    private func keep(
        _ book: PublishedBook, in directory: () throws(SnapshotFailure) -> URL, now: Date,
        _ destination: Destination
    ) -> SnapshotOutcome {
        do throws(SnapshotFailure) {
            let directory = try directory()
            let snapshots = try existingSnapshots(in: directory)
            guard SnapshotSchedule.decision(snapshots: snapshots.map(\.date), now: now) == .due else {
                return .notDue
            }
            let pruning = prune(snapshots, in: directory, now: now)
            try write(book, in: directory, now: now)
            if let pruning { throw pruning }
            return .written
        } catch {
            error.log(destination)
            return .failed(error)
        }
    }

    /// Only regular files whose names are exactly snapshot names; nothing else is ever pruned.
    private func existingSnapshots(in directory: URL) throws(SnapshotFailure) -> [SnapshotName] {
        let entries: [DirectoryEntry]
        do {
            entries = try fileSystem.contents(of: directory)
        } catch  where error.cause == .notFound {
            try createDirectories([directory])
            return []
        } catch {
            throw .fileSystem(.list, error)
        }
        return entries.filter { $0.kind == .file }.compactMap { SnapshotName(fileName: $0.name) }
    }

    /// Removes what the schedule says to, carrying on past failures; returns the first.
    private func prune(_ snapshots: [SnapshotName], in directory: URL, now: Date) -> SnapshotFailure? {
        let doomed = SnapshotSchedule.toDelete(Set(snapshots.map(\.date)), now: now)
        var failure: SnapshotFailure?
        for snapshot in snapshots where doomed.contains(snapshot.date) {
            do {
                try fileSystem.remove(
                    directory.appending(path: snapshot.fileName, directoryHint: .notDirectory))
            } catch  where error.cause == .notFound {
                continue
            } catch {
                failure = failure ?? .fileSystem(.prune, error)
            }
        }
        return failure
    }

    private func write(_ book: PublishedBook, in directory: URL, now: Date) throws(SnapshotFailure) {
        guard let name = SnapshotName(date: now) else { throw .clockOutOfRange }
        try writeDurably(
            book.data, to: directory.appending(path: name.fileName, directoryHint: .notDirectory),
            over: .nothing, .write)
    }

    // MARK: - The mirror folder and the book's id

    /// This book's folder in the mirror, claimed for this package. See `BackupMirror` for how
    /// a copied package is told apart from a moved one.
    private func mirrorFolder() throws(SnapshotFailure) -> URL {
        let id = try bookID()
        let folder = mirror.folder(for: id)
        let ourPath = BackupMirror.path(of: layout.root)
        switch try recordedPackage(of: folder) {
        case .at(ourPath):
            return folder
        case .none:
            try claim(folder, for: ourPath, over: .nothing)
            return folder
        case .at(let otherPath) where holdsBook(id, at: otherPath):
            Log.backup.info("a package is a copy of another book; giving it a new book id")
            let newID = try recordNewBookID(over: .existingFile)
            let newFolder = mirror.folder(for: newID)
            try claim(newFolder, for: ourPath, over: .nothing)
            return newFolder
        case .at, .unrecognized:
            Log.backup.info("a book's package moved; its mirror folder follows it")
            try claim(folder, for: ourPath, over: .existingFile)
            return folder
        }
    }

    /// The id in `Backups/book-id`, made on first need. A corrupt id is replaced, which starts
    /// a new mirror folder; one that can't be read is reported and left alone.
    private func bookID() throws(SnapshotFailure) -> UUID {
        switch try storedID(at: layout.bookID) {
        case .valid(let id):
            return id
        case .absent:
            return try recordNewBookID(over: .nothing)
        case .corrupt:
            Log.backup.error("book-id is corrupt; giving the book a new id and a new mirror folder")
            return try recordNewBookID(over: .existingFile)
        }
    }

    /// Durable before it's returned, so a mirror folder is only ever named by a stored id.
    private func recordNewBookID(over existing: Existing) throws(SnapshotFailure) -> UUID {
        let id = UUID()
        try writeDurably(Data("\(id.uuidString)\n".utf8), to: layout.bookID, over: existing, .writeBookID)
        Log.backup.info("recorded a new book id", ["id": .id(id)])
        return id
    }

    private enum StoredID: Equatable {
        case valid(UUID)
        case absent
        case corrupt
    }

    private func storedID(at url: URL) throws(SnapshotFailure) -> StoredID {
        let data: Data
        do {
            data = try fileSystem.read(url)
        } catch  where error.cause.meansAbsent {
            return .absent
        } catch {
            throw .fileSystem(.readBookID, error)
        }
        guard let text = String(data: data, encoding: .utf8),
            let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .corrupt }
        return .valid(id)
    }

    /// Whether the package at `path` holds `id`. Anything but a clear "no" counts as yes:
    /// a wrong yes only starts a new mirror folder, but a wrong no would mix two books' snapshots.
    private func holdsBook(_ id: UUID, at path: String) -> Bool {
        let other = PackageLayout(root: URL(filePath: path, directoryHint: .isDirectory))
        do {
            return try storedID(at: other.bookID) == .valid(id)
        } catch {
            return true
        }
    }

    private enum RecordedPackage: Equatable {
        case none
        case at(String)
        /// Not an absolute path.
        case unrecognized
    }

    private func recordedPackage(of folder: URL) throws(SnapshotFailure) -> RecordedPackage {
        let data: Data
        do {
            data = try fileSystem.read(BackupMirror.packagePathFile(in: folder))
        } catch  where error.cause.meansAbsent {
            return .none
        } catch {
            throw .fileSystem(.readMirrorOwner, error)
        }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return path.hasPrefix("/") ? .at(path) : .unrecognized
    }

    private func claim(_ folder: URL, for path: String, over existing: Existing) throws(SnapshotFailure) {
        if existing == .nothing {
            try createDirectories([mirror.root.deletingLastPathComponent(), mirror.root, folder])
        }
        try writeDurably(
            Data("\(path)\n".utf8), to: BackupMirror.packagePathFile(in: folder), over: existing,
            .writeMirrorOwner)
    }

    // MARK: - File-system helpers

    private enum Existing {
        /// Nothing may be at the destination.
        case nothing
        case existingFile
    }

    private func writeDurably(_ data: Data, to url: URL, over existing: Existing, _ step: SnapshotStep)
        throws(SnapshotFailure)
    {
        let temporary: TemporaryFile
        do {
            temporary = try fileSystem.writeTemporary(data, for: url, permissionsFrom: url)
        } catch {
            throw .fileSystem(step, error)
        }
        do {
            switch existing {
            case .nothing: try fileSystem.publish(temporary, as: url)
            case .existingFile: try fileSystem.move(temporary.url, over: url)
            }
        } catch {
            fileSystem.discard(temporary.url)
            throw .fileSystem(step, error)
        }
    }

    /// Creates each directory that's missing, in order; each one's parent must exist.
    private func createDirectories(_ urls: [URL]) throws(SnapshotFailure) {
        for url in urls {
            do {
                try fileSystem.createDirectory(at: url)
            } catch  where error.cause == .alreadyExists {
                continue
            } catch {
                throw .fileSystem(.createFolder, error)
            }
        }
    }
}

/// Where snapshots are mirrored outside every package: one folder per book id, normally under
/// `~/Library/Application Support/Scene It/Backups/`.
///
/// A copied package carries its original's `book-id`, and the two must not share a folder.
/// So each folder records the path of the package that writes to it (`package-path`). A
/// package that finds another path recorded checks the package there: if it holds the same
/// id, this package is a copy and takes a new id (and folder); otherwise the book moved, and
/// the folder follows it.
public struct BackupMirror: Hashable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var standard: BackupMirror {
        BackupMirror(
            root: URL.applicationSupportDirectory.appending(path: "Scene It", directoryHint: .isDirectory)
                .appending(path: "Backups", directoryHint: .isDirectory))
    }

    public func folder(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static func packagePathFile(in folder: URL) -> URL {
        folder.appending(path: "package-path", directoryHint: .notDirectory)
    }

    static func path(of package: URL) -> String {
        let path = package.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// What a save's snapshots did, for the status bar.
public struct SnapshotReport: Hashable, Sendable {
    public let package: SnapshotOutcome
    public let mirror: SnapshotOutcome

    public var failures: [SnapshotFailure] {
        [package, mirror].compactMap { outcome in
            if case .failed(let failure) = outcome { failure } else { nil }
        }
    }
}

public enum SnapshotOutcome: Hashable, Sendable {
    case written
    /// The newest snapshot is younger than the finest tier's spacing.
    case notDue
    /// A snapshot may still have been written if only pruning failed.
    case failed(SnapshotFailure)
}

public enum SnapshotFailure: Error, Hashable, Sendable {
    case fileSystem(SnapshotStep, FileSystemError)
    /// The clock reads a year outside 1970…9999, which a snapshot name doesn't express.
    case clockOutOfRange
}

public enum SnapshotStep: Hashable, Sendable {
    case createFolder, list, prune, write
    case readBookID, writeBookID
    /// The mirror folder's record of which package writes to it.
    case readMirrorOwner, writeMirrorOwner

    var logSymbol: StaticString {
        switch self {
        case .createFolder: "createFolder"
        case .list: "list"
        case .prune: "prune"
        case .write: "write"
        case .readBookID: "readBookID"
        case .writeBookID: "writeBookID"
        case .readMirrorOwner: "readMirrorOwner"
        case .writeMirrorOwner: "writeMirrorOwner"
        }
    }
}

private enum Destination {
    case package, mirror

    var logSymbol: StaticString {
        switch self {
        case .package: "package"
        case .mirror: "mirror"
        }
    }
}

extension SnapshotFailure {
    fileprivate func log(_ destination: Destination) {
        switch self {
        case .clockOutOfRange:
            Log.backup.error(
                "couldn't take a snapshot: the clock is out of range",
                ["destination": .symbol(destination.logSymbol)])
        case .fileSystem(let step, let error):
            let reason: LogValue =
                if case .other(let code) = error.cause { .errno(code.rawValue) } else {
                    .symbol(error.cause.logSymbol)
                }
            Log.backup.error(
                "couldn't take a snapshot",
                [
                    "destination": .symbol(destination.logSymbol), "step": .symbol(step.logSymbol),
                    "operation": .symbol(error.operation.logSymbol), "cause": reason,
                ])
        }
    }
}

extension FileSystemError.Cause {
    /// Nothing is there: the file is missing, or a directory on its path is.
    fileprivate var meansAbsent: Bool {
        self == .notFound || self == .other(.ENOTDIR)
    }
}
