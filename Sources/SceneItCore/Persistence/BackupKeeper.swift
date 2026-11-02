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

    /// Call with the `PublishedBook` of each `.saved` outcome, off the main actor: when a
    /// snapshot is due this flushes two files to the drive. Calls for one book should be
    /// serialized, like its saves. Each destination decides on its own whether a snapshot is
    /// due, and prunes its own snapshots before writing one. When one is due, it also clears
    /// away the temporary files an interrupted `keep` left in its folder (`StrayTemporaryFiles`),
    /// whatever the snapshot's outcome, never failing because of them.
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
            defer { strayTemporaryFiles(in: directory, destination).sweep(now: now) }
            let pruning = prune(snapshots, in: directory, now: now)
            try write(book, in: directory, now: now)
            if let pruning { throw pruning }
            return .written
        } catch {
            error.log(destination)
            return .failed(error)
        }
    }

    private func strayTemporaryFiles(in directory: URL, _ destination: Destination) -> StrayTemporaryFiles {
        switch destination {
        case .package:
            StrayTemporaryFiles(
                snapshotsIn: directory, metadata: layout.bookID, isValid: { Self.bookID(from: $0) != nil },
                alsoKept: StrayTemporaryFiles.packageVersions(layout), fileSystem: fileSystem)
        case .mirror:
            StrayTemporaryFiles(
                snapshotsIn: directory, metadata: BackupMirror.packageRecord(in: directory),
                isValid: { Self.packageRecord(from: $0) != nil }, alsoKept: [], fileSystem: fileSystem)
        }
    }

    /// Only regular files whose names are exactly snapshot names; nothing else is ever pruned.
    private func existingSnapshots(in directory: URL) throws(SnapshotFailure) -> [SnapshotName] {
        try requireRealFolder(directory, ifMissing: .create)
        let entries: [DirectoryEntry]
        do {
            entries = try fileSystem.contents(of: directory)
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
        try requireRealFolder(layout.snapshots, ifMissing: .create)
        let id = try bookID()
        let folder = mirror.folder(for: id)
        try requireRealFolder(folder, ifMissing: .leave)
        let us = try ourRecord()
        switch try recordedPackage(of: folder) {
        case .none:
            try claim(folder, for: us, over: .nothing)
            return folder
        case .unrecognized:
            return try fork(us)
        case .recorded(let recorded):
            switch Self.ownership(recorded, us) {
            case .ours:
                return folder
            case .oursMoved:
                try claim(folder, for: us, over: .existingFile)
                return folder
            case .another:
                return try fork(us)
            case .unknown where holdsBook(id, at: recorded.path):
                return try fork(us)
            case .unknown:
                Log.backup.info("a book's package moved; its mirror folder follows it")
                try claim(folder, for: us, over: .existingFile)
                return folder
            }
        }
    }

    private enum Ownership {
        case ours
        /// The same directory, at a new path on its volume.
        case oursMoved
        /// A different directory, at this package's path: a replacement or a clone.
        case another
        /// Only the recorded path can tell.
        case unknown
    }

    /// Decided by identity when both sides have one, so the recorded path is only read when
    /// this package moved to another volume or its volume has no UUID.
    private static func ownership(_ recorded: PackageRecord, _ us: PackageRecord) -> Ownership {
        guard let theirs = recorded.identity, let ours = us.identity else {
            return recorded.path == us.path ? .ours : .unknown
        }
        switch (theirs == ours, recorded.path == us.path) {
        case (true, true): return .ours
        case (true, false): return .oursMoved
        case (false, true): return .another
        case (false, false): return .unknown
        }
    }

    private func fork(_ us: PackageRecord) throws(SnapshotFailure) -> URL {
        Log.backup.info("this package is a copy of another book; giving it a new book id")
        let folder = mirror.folder(for: try recordNewBookID(over: .existingFile))
        try claim(folder, for: us, over: .nothing)
        return folder
    }

    private func ourRecord() throws(SnapshotFailure) -> PackageRecord {
        do {
            return PackageRecord(
                path: BackupMirror.path(of: layout.root), identity: try fileSystem.identity(of: layout.root))
        } catch {
            throw .fileSystem(.identifyPackage, error)
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
        return Self.bookID(from: data).map(StoredID.valid) ?? .corrupt
    }

    private static func bookID(from data: Data) -> UUID? {
        String(data: data, encoding: .utf8).flatMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
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

    private enum RecordedPackage {
        case none
        case recorded(PackageRecord)
        /// Not a record this code wrote.
        case unrecognized
    }

    private func recordedPackage(of folder: URL) throws(SnapshotFailure) -> RecordedPackage {
        let data: Data
        do {
            data = try fileSystem.read(BackupMirror.packageRecord(in: folder))
        } catch  where error.cause.meansAbsent {
            return .none
        } catch {
            throw .fileSystem(.readMirrorOwner, error)
        }
        return Self.packageRecord(from: data).map(RecordedPackage.recorded) ?? .unrecognized
    }

    private static func packageRecord(from data: Data) -> PackageRecord? {
        guard let record = try? JSONDecoder().decode(PackageRecord.self, from: data),
            record.path.hasPrefix("/")
        else { return nil }
        return record
    }

    private func claim(_ folder: URL, for record: PackageRecord, over existing: Existing)
        throws(SnapshotFailure)
    {
        try createDirectories([mirror.root.deletingLastPathComponent(), mirror.root, folder])
        try requireRealFolder(folder, ifMissing: .leave)
        let data: Data
        do {
            data = try Self.recordEncoder.encode(record)
        } catch {
            Log.backup.fault("couldn't encode a package record", ["error": .error(LoggedError(error))])
            throw .fileSystem(
                .writeMirrorOwner, FileSystemError(.write, BackupMirror.packageRecord(in: folder), .io))
        }
        try writeDurably(data, to: BackupMirror.packageRecord(in: folder), over: existing, .writeMirrorOwner)
    }

    private static let recordEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

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
            // Another keeper raced us to the same name with the same bytes: what we wanted.
            if error.cause == .alreadyExists, (try? fileSystem.read(url)) == data { return }
            throw .fileSystem(step, error)
        }
    }

    private enum Missing {
        case create
        case leave
    }

    /// Refuses a link (or anything else) where one of our folders should be, before anything
    /// in it is read or written: through a link, `book-id` could be another book's.
    private func requireRealFolder(_ url: URL, ifMissing missing: Missing) throws(SnapshotFailure) {
        let item: FileItem?
        do {
            item = try fileSystem.item(at: url)
        } catch {
            throw .fileSystem(.list, error)
        }
        switch (item, missing) {
        case (.directory?, _), (nil, .leave): return
        case (nil, .create): try createDirectories([url])
        case (.file?, _), (.symbolicLink?, _), (.other?, _): throw .notARealFolder
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
/// So each folder records the package that writes to it (`package.json`): its path and its
/// `FileIdentity`. The same identity at another path is the same package, moved; another
/// identity at the same path is a different package, so it takes a new id (and folder).
/// Otherwise the package at the recorded path is checked: if it holds the same id, this
/// package is a copy and forks; if not, the book moved to another volume and the folder
/// follows it.
public struct BackupMirror: Hashable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var standard: BackupMirror {
        BackupMirror(root: SupportFolder.root.appending(path: "Backups", directoryHint: .isDirectory))
    }

    public func folder(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static func packageRecord(in folder: URL) -> URL {
        folder.appending(path: "package.json", directoryHint: .notDirectory)
    }

    static func path(of package: URL) -> String {
        package.canonicalPath
    }
}

/// The package that writes to a mirror folder.
struct PackageRecord: Hashable, Codable {
    let path: String
    /// `nil` on a volume without a UUID.
    let identity: FileIdentity?
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
    /// The package's `Backups/` or the book's mirror folder is a symbolic link or not a
    /// folder, so nothing in it is read, written or pruned.
    case notARealFolder
}

public enum SnapshotStep: Hashable, Sendable {
    case createFolder, list, prune, write
    case readBookID, writeBookID
    /// The mirror folder's record of which package writes to it.
    case readMirrorOwner, writeMirrorOwner
    /// Finding the package directory's `FileIdentity`.
    case identifyPackage

    var logSymbol: StaticString {
        switch self {
        case .identifyPackage: "identifyPackage"
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
        case .notARealFolder:
            Log.backup.error(
                "couldn't take a snapshot: its folder is a link or not a folder",
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
