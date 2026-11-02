import CryptoKit
import Foundation
import Synchronization

/// An open `.sceneit` package: creates, opens and saves `book.json`, rotating
/// `book.json.bak1…3` on each save that changes it.
///
/// It remembers which `book.json` it last read or wrote, and won't silently save over a
/// different one. A class, so that two copies can't disagree about that; saves are
/// serialized by its lock.
public final class BookPackage: Sendable {
    public let layout: PackageLayout
    private let fileSystem: any FileSystem
    private let lastSeen: Mutex<KnownVersion>

    private init(layout: PackageLayout, fileSystem: any FileSystem, lastSeen: KnownVersion) {
        self.layout = layout
        self.fileSystem = fileSystem
        self.lastSeen = Mutex(lastSeen)
    }

    static let emptyArchiveIndex = Data(#"{"copies":[]}"#.utf8)

    /// A new package holding an empty book: no scenes, as PLAN §4.2 allows.
    /// `book.json` is written last, so a package left half-made by a failure won't open.
    public static func create(
        at url: URL, title: String, fileSystem: any FileSystem = LocalFileSystem()
    ) throws(CreateError) -> OpenedBook {
        let layout = PackageLayout(root: url)
        guard layout.hasPackageExtension else { throw .missingPackageExtension(url) }
        let book = Book(title: title)
        let data: Data
        do {
            data = try verifiedEncoding(of: book)
        } catch {
            throw .encoding(error)
        }
        do {
            try fileSystem.createDirectory(at: url)
        } catch  where error.cause == .alreadyExists {
            throw .alreadyExists(url)
        } catch {
            throw .fileSystem(error)
        }
        do {
            try fileSystem.createDirectory(at: layout.archive)
            _ = try writeFile(emptyArchiveIndex, to: layout.archiveIndex, fileSystem)
            try fileSystem.createDirectory(at: layout.snapshots)
            let stamp = try writeFile(data, to: layout.book, fileSystem)
            let package = BookPackage(
                layout: layout, fileSystem: fileSystem, lastSeen: KnownVersion(stamp: stamp, contents: data))
            return OpenedBook(package: package, book: book)
        } catch {
            Log.store.error("couldn't create a book package", error.logMetadata)
            throw .fileSystem(error)
        }
    }

    /// Reads, decodes and validates `book.json`, all or nothing. Never writes.
    public static func open(
        at url: URL, fileSystem: any FileSystem = LocalFileSystem()
    ) throws(LoadError) -> OpenedBook {
        let layout = PackageLayout(root: url)
        do {
            let (book, version) = try load(layout, fileSystem)
            Log.store.info(
                "opened a book", ["bytes": .bytes(version.stamp.size), "scenes": .count(book.scenes.count)])
            return OpenedBook(
                package: BookPackage(layout: layout, fileSystem: fileSystem, lastSeen: version), book: book)
        } catch {
            let backups = existingBackups(layout, fileSystem)
            Log.store.error(
                "couldn't open a book",
                ["problem": .symbol(error.logSymbol), "backups": .count(backups.count)])
            throw LoadError(package: url, problem: error, backups: backups)
        }
    }

    /// Writes `book` unless `book.json` already holds exactly its encoding.
    ///
    /// When this throws, `book.json` is unchanged. Every write happens before anything is
    /// renamed, so a full disk or an I/O error leaves the backups untouched as well; only a
    /// failed rename can cost a backup (see chapter 03 of the tutorial).
    public func save(
        _ book: Book, onExternalChange policy: ExternalChangePolicy = .refuse
    ) throws(SaveError) -> SaveOutcome {
        let data: Data
        do {
            data = try BookCoding.encode(book)
        } catch {
            Log.store.error(
                "refused to save a book that doesn't encode", ["error": .error(LoggedError(error))])
            throw .encoding(.rejected(error))
        }
        return try save(encoded: data, onExternalChange: policy)
    }

    func save(
        encoded data: Data, onExternalChange policy: ExternalChangePolicy = .refuse
    ) throws(SaveError) -> SaveOutcome {
        do {
            try Self.verify(data)
        } catch {
            Log.store.fault("the encoded book failed verification", ["error": .error(LoggedError(error))])
            throw .encoding(error)
        }
        return try lastSeen.withLock { (lastSeen) throws(SaveError) -> SaveOutcome in
            let current = try readCurrent(&lastSeen, policy)
            if current == data {
                Log.store.debug("book unchanged; nothing saved")
                return .unchanged
            }
            let (stamp, backups) = try replaceBook(with: data, backingUp: current)
            lastSeen = KnownVersion(stamp: stamp, contents: data)
            Log.store.info("saved the book", ["bytes": .bytes(stamp.size)])
            return .saved(backups)
        }
    }

    /// The bytes of `book.json`, or `nil` if it was removed and `policy` allows recreating it.
    /// Adopts a new stamp when `book.json` was touched or copied but holds what we last wrote.
    private func readCurrent(
        _ lastSeen: inout KnownVersion, _ policy: ExternalChangePolicy
    ) throws(SaveError) -> Data? {
        let item = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
            try fileSystem.item(at: layout.book)
        }
        switch item {
        case nil:
            guard policy == .overwriteKeepingTheirsAsBackup else { throw refusal(.removed) }
            return nil
        case .directory, .symbolicLink, .other:
            throw refusal(.notAFile)
        case .file(let stamp, let protection):
            guard protection == .writable else { throw .writeProtected(protection) }
            let current = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
                try fileSystem.read(layout.book)
            }
            if stamp != lastSeen.stamp {
                if ContentDigest(current) == lastSeen.digest {
                    lastSeen.stamp = stamp
                } else if policy == .refuse {
                    throw refusal(.changed)
                }
            }
            return current
        }
    }

    private func refusal(_ change: ExternalChange) -> SaveError {
        Log.store.error("refused to save over a book.json changed by another program")
        return .externallyModified(change)
    }

    /// Writes both temporary files first, so every failure that leaves the disk unchanged
    /// happens before any rename. Then the renames: the backup rotation (best effort),
    /// then `book.json`.
    private func replaceBook(
        with data: Data, backingUp current: Data?
    ) throws(SaveError) -> (FileStamp, BackupStatus) {
        var backup: (file: TemporaryFile, bak1: Bak1)?
        do throws(FileSystemError) {
            if let current, case let bak1 = bak1Holding(current), bak1 != .holdsCurrent {
                let file = try fileSystem.writeTemporary(
                    current, for: layout.backup(.bak1), permissionsFrom: layout.book)
                backup = (file, bak1)
            }
            let replacement = try fileSystem.writeTemporary(
                data, for: layout.book, permissionsFrom: layout.book)
            let status = backup.map { rotateBackups(publishing: $0.file, over: $0.bak1) } ?? .intact
            backup = nil
            do {
                try fileSystem.publish(replacement, as: layout.book)
            } catch {
                fileSystem.discard(replacement)
                throw error
            }
            return (replacement.stamp, status)
        } catch {
            if let backup { fileSystem.discard(backup.file) }
            Log.store.error("couldn't save the book", error.logMetadata)
            throw .fileSystem(error)
        }
    }

    private enum Bak1 {
        case holdsCurrent, absent, holdsOther
    }

    /// Anything that can't be read counts as different, so a damaged slot never blocks a save.
    private func bak1Holding(_ current: Data) -> Bak1 {
        let url = layout.backup(.bak1)
        let item: FileItem?
        do {
            item = try fileSystem.item(at: url)
        } catch {
            return .holdsOther
        }
        guard let item else { return .absent }
        guard case .file(let stamp, _) = item, stamp.size == current.count,
            let contents = try? fileSystem.read(url), contents == current
        else { return .holdsOther }
        return .holdsCurrent
    }

    /// Shifts `bak2`→`bak3` and `bak1`→`bak2` (unless `bak1` is empty), then publishes
    /// `backup` as `bak1`. A step that fails doesn't stop the later ones: the newest versions
    /// are the ones worth keeping.
    private func rotateBackups(publishing backup: TemporaryFile, over bak1: Bak1) -> BackupStatus {
        var failures: [FileSystemError] = []
        if bak1 == .holdsOther {
            for (source, destination) in [(BackupSlot.bak2, BackupSlot.bak3), (.bak1, .bak2)] {
                do {
                    try fileSystem.move(layout.backup(source), over: layout.backup(destination))
                } catch  where error.cause == .notFound {
                    continue
                } catch {
                    failures.append(error)
                }
            }
        }
        do {
            try fileSystem.publish(backup, as: layout.backup(.bak1))
        } catch {
            fileSystem.discard(backup)
            failures.append(error)
        }
        guard let first = failures.first else { return .intact }
        Log.store.error("couldn't rotate the backups; saving the book anyway", first.logMetadata)
        return .degraded(first)
    }

    private static func writeFile(
        _ data: Data, to url: URL, _ fileSystem: any FileSystem
    ) throws(FileSystemError) -> FileStamp {
        let temporary = try fileSystem.writeTemporary(data, for: url, permissionsFrom: url)
        do {
            try fileSystem.publish(temporary, as: url)
        } catch {
            fileSystem.discard(temporary)
            throw error
        }
        return temporary.stamp
    }

    /// Encodes `book` and checks that the bytes are a fixed point of decode → encode.
    static func verifiedEncoding(of book: Book) throws(EncodingFailure) -> Data {
        let data: Data
        do {
            data = try BookCoding.encode(book)
        } catch {
            throw .rejected(error)
        }
        try verify(data)
        return data
    }

    /// Compares bytes, not `Book`s: `String`'s `==` treats canonically equivalent text
    /// (NFC and NFD) as equal, so equal books can still encode differently.
    static func verify(_ data: Data) throws(EncodingFailure) {
        let decoded: Book
        do {
            decoded = try BookCoding.decode(data)
        } catch {
            throw .undecodable(error)
        }
        let reencoded: Data
        do {
            reencoded = try BookCoding.encode(decoded)
        } catch {
            throw .reencodingRejected(error)
        }
        guard reencoded == data else { throw .unstable }
    }

    /// The stamp is taken before reading, so a change made while reading makes the next
    /// save see a mismatch instead of silently overwriting it.
    private static func load(
        _ layout: PackageLayout, _ fileSystem: any FileSystem
    ) throws(LoadProblem) -> (Book, KnownVersion) {
        guard layout.hasPackageExtension else { throw .missingPackageExtension }
        let unreadable = LoadProblem.unreadable
        switch try wrapping(
            unreadable, { () throws(FileSystemError) in try fileSystem.item(at: layout.root) })
        {
        case nil: throw .notFound
        case .file, .symbolicLink, .other: throw .notADirectory
        case .directory: break
        }
        let stamp: FileStamp
        switch try wrapping(
            unreadable, { () throws(FileSystemError) in try fileSystem.item(at: layout.book) })
        {
        case nil: throw .bookMissing
        case .directory, .symbolicLink, .other: throw .bookNotAFile
        case .file(let bookStamp, _): stamp = bookStamp
        }
        let data = try wrapping(unreadable) { () throws(FileSystemError) in try fileSystem.read(layout.book) }
        let book: Book
        do {
            book = try BookCoding.decode(data)
        } catch {
            throw .undecodable(error)
        }
        let problems = BookValidator.problems(in: book)
        guard problems.isEmpty else { throw .invalid(problems) }
        return (book, KnownVersion(stamp: stamp, contents: data))
    }

    private static func existingBackups(_ layout: PackageLayout, _ fileSystem: any FileSystem) -> [Backup] {
        BackupSlot.allCases.compactMap { slot in
            guard case .file(let stamp, _) = try? fileSystem.item(at: layout.backup(slot)) else { return nil }
            return Backup(slot: slot, modified: stamp.modified)
        }
    }
}

/// The `book.json` this package last read or wrote.
private struct KnownVersion: Sendable {
    var stamp: FileStamp
    let digest: ContentDigest

    init(stamp: FileStamp, contents: Data) {
        self.stamp = stamp
        digest = ContentDigest(contents)
    }
}

/// SHA-256 of a file's contents, so recognizing our own bytes doesn't mean keeping a copy.
private struct ContentDigest: Hashable, Sendable {
    let bytes: Data

    init(_ contents: Data) {
        bytes = Data(SHA256.hash(data: contents))
    }
}

/// Runs `body`, turning its file-system error into the caller's error type.
private func wrapping<T, E: Error>(
    _ wrap: (FileSystemError) -> E, _ body: () throws(FileSystemError) -> T
) throws(E) -> T {
    do {
        return try body()
    } catch {
        throw wrap(error)
    }
}

public struct OpenedBook: Sendable {
    public let package: BookPackage
    public let book: Book
}
