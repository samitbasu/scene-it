import CryptoKit
import Foundation
import Synchronization

/// An open `.sceneit` package: creates, opens and saves `book.json`, rotating
/// `book.json.bak1…3` on each save that changes it.
///
/// It remembers a digest of the `book.json` it last read or wrote, and won't silently save
/// over a different one. A class, so that two copies can't disagree about that; saves are
/// serialized by its lock.
public final class BookPackage: Sendable {
    public let layout: PackageLayout
    private let fileSystem: any FileSystem
    private let lastSeen: Mutex<ContentDigest>

    private init(layout: PackageLayout, fileSystem: any FileSystem, lastSeen: ContentDigest) {
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
            try writeNewFile(emptyArchiveIndex, at: layout.archiveIndex, fileSystem)
            try fileSystem.createDirectory(at: layout.snapshots)
            try writeNewFile(data, at: layout.book, fileSystem)
            let package = BookPackage(layout: layout, fileSystem: fileSystem, lastSeen: ContentDigest(data))
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
            let (book, data) = try load(layout, fileSystem)
            Log.store.info(
                "opened a book", ["bytes": .bytes(Int64(data.count)), "scenes": .count(book.scenes.count)])
            return OpenedBook(
                package: BookPackage(layout: layout, fileSystem: fileSystem, lastSeen: ContentDigest(data)),
                book: book)
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
    /// The backup policy is ADR 0019: another program's version is never replaced unless it's
    /// safely in `bak1`; this package's own previous save is replaced even if it couldn't be
    /// backed up, and the outcome says so. When this throws, `book.json` is unchanged.
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
            let current = try readCurrent(lastSeen, policy)
            if current?.data == data {
                Log.store.debug("book unchanged; nothing saved")
                return .unchanged
            }
            let backups = try replaceBook(with: data, current: current, &lastSeen)
            lastSeen = ContentDigest(data)
            Log.store.info("saved the book", ["bytes": .bytes(Int64(data.count))])
            return .saved(backups)
        }
    }

    /// What `book.json` holds now, and whose it is.
    private struct Current {
        let data: Data
        let owner: Owner
    }

    private enum Owner {
        /// The bytes are this package's own last read or write.
        case ours
        case theirs
    }

    /// `nil` if `book.json` was removed and `policy` allows recreating it.
    private func readCurrent(_ lastSeen: ContentDigest, _ policy: ExternalChangePolicy) throws(SaveError)
        -> Current?
    {
        let item = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
            try fileSystem.item(at: layout.book)
        }
        switch item {
        case nil:
            guard policy == .overwriteKeepingTheirsAsBackup else { throw refusal(.removed) }
            return nil
        case .directory, .symbolicLink, .other:
            throw refusal(.notAFile)
        case .file(_, let protection):
            if let protection { throw .writeProtected(protection) }
            let data = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
                try fileSystem.read(layout.book)
            }
            if ContentDigest(data) == lastSeen { return Current(data: data, owner: .ours) }
            guard policy == .overwriteKeepingTheirsAsBackup else { throw refusal(.changed) }
            return Current(data: data, owner: .theirs)
        }
    }

    private func refusal(_ change: ExternalChange) -> SaveError {
        Log.store.error("refused to save over a book.json changed by another program")
        return .externallyModified(change)
    }

    /// Writes both temporary files first, so every failure that leaves the disk unchanged
    /// happens before any rename. Then the renames: the backup rotation, then `book.json`.
    private func replaceBook(
        with data: Data, current: Current?, _ lastSeen: inout ContentDigest
    ) throws(SaveError) -> BackupStatus {
        var unpublished: [URL] = []
        do throws(SaveError) {
            var backup: (file: TemporaryFile, bak1: Bak1)?
            if let current {
                let bak1 = bak1Holding(current.data)
                if bak1 != .holdsCurrent {
                    let file = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
                        try fileSystem.writeTemporary(
                            current.data, for: layout.backup(.bak1), permissionsFrom: layout.book)
                    }
                    unpublished.append(file.url)
                    backup = (file, bak1)
                }
            }
            let replacement = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
                try fileSystem.writeTemporary(data, for: layout.book, permissionsFrom: layout.book)
            }
            unpublished.append(replacement.url)
            var status = BackupStatus.intact
            if let backup, let current {
                do {
                    try rotateBackups(publishing: backup.file, over: backup.bak1)
                } catch {
                    guard current.owner == .ours else { throw .couldNotBackUpTheirVersion(error.cause) }
                    Log.store.error(
                        "couldn't back up the previous version; saving anyway", error.cause.logMetadata)
                    fileSystem.discard(backup.file.url)
                    status = .previousVersionNotBackedUp(error.cause, olderBackups: error.olderBackups)
                }
            }
            unpublished = []
            try replace(with: replacement, expecting: current?.data, &lastSeen)
            return status
        } catch {
            unpublished.forEach(fileSystem.discard)
            Log.store.error("couldn't save the book")
            throw error
        }
    }

    private enum Bak1 {
        case holdsCurrent, absent, holdsOther
    }

    /// Anything that can't be read counts as different, so a damaged slot never stops a save.
    private func bak1Holding(_ current: Data) -> Bak1 {
        let url = layout.backup(.bak1)
        let item: FileItem?
        do {
            item = try fileSystem.item(at: url)
        } catch {
            return .holdsOther
        }
        guard let item else { return .absent }
        guard case .file(let metadata, _) = item, metadata.size == current.count,
            let contents = try? fileSystem.read(url), contents == current
        else { return .holdsOther }
        return .holdsCurrent
    }

    /// Shifts `bak2`→`bak3` and `bak1`→`bak2` (unless `bak1` is empty, which absorbs the shift),
    /// then publishes `backup` into the empty `bak1`. Stops at the first failure, so it never
    /// destroys a version other than the one in `bak3`.
    private func rotateBackups(publishing backup: TemporaryFile, over bak1: Bak1) throws(RotationFailure) {
        var olderBackups = OlderBackups.untouched
        let shifts: [(BackupSlot, BackupSlot)] = bak1 == .absent ? [] : [(.bak2, .bak3), (.bak1, .bak2)]
        for (source, destination) in shifts {
            do {
                try fileSystem.move(layout.backup(source), over: layout.backup(destination))
            } catch  where error.cause == .notFound {
                continue
            } catch {
                throw RotationFailure(cause: error, olderBackups: olderBackups)
            }
            if destination == .bak3 { olderBackups = .oldestRetired }
        }
        do {
            try fileSystem.publish(backup, as: layout.backup(.bak1))
        } catch {
            throw RotationFailure(cause: error, olderBackups: olderBackups)
        }
    }

    private struct RotationFailure: Error {
        let cause: FileSystemError
        let olderBackups: OlderBackups
    }

    /// Replaces `book.json` only if it still holds `expected` (or, for `nil`, nothing), and
    /// disposes of `replacement`.
    ///
    /// With `exchange`, the check happens after the swap, so no window remains: if the
    /// displaced file isn't `expected`, another program wrote it after `readCurrent`, and it's
    /// swapped back. Volumes that can't swap get a re-check just before a plain rename.
    private func replace(
        with replacement: TemporaryFile, expecting expected: Data?, _ lastSeen: inout ContentDigest
    ) throws(SaveError) {
        guard let expected else {
            do {
                return try fileSystem.publish(replacement, as: layout.book)
            } catch {
                fileSystem.discard(replacement.url)
                throw error.cause == .alreadyExists ? refusal(.changed) : .fileSystem(error)
            }
        }
        do {
            try fileSystem.exchange(replacement, with: layout.book)
        } catch  where error.cause == .unsupported {
            return try replaceWithoutExchange(replacement, expecting: expected)
        } catch {
            fileSystem.discard(replacement.url)
            throw .fileSystem(error)
        }
        if (try? fileSystem.read(replacement.url)) == expected {
            fileSystem.discard(replacement.url)
            return
        }
        do {
            try fileSystem.exchange(replacement, with: layout.book)
        } catch {
            throw keepAsConflict(replacement, &lastSeen)
        }
        fileSystem.discard(replacement.url)
        throw refusal(.changed)
    }

    /// For volumes that can't swap (FAT, exFAT, HFS+). A change landing between this re-read
    /// and the rename is lost; the window is a few microseconds.
    private func replaceWithoutExchange(_ replacement: TemporaryFile, expecting expected: Data)
        throws(SaveError)
    {
        guard (try? fileSystem.read(layout.book)) == expected else {
            fileSystem.discard(replacement.url)
            throw refusal(.changed)
        }
        do {
            try fileSystem.move(replacement.url, over: layout.book)
        } catch {
            fileSystem.discard(replacement.url)
            throw .fileSystem(error)
        }
    }

    /// `book.json` now holds this save and the other program's version sits at the temporary
    /// name, which nothing reads; give it a visible name so it isn't lost.
    private func keepAsConflict(_ displaced: TemporaryFile, _ lastSeen: inout ContentDigest) -> SaveError {
        if let ours = try? fileSystem.read(layout.book) { lastSeen = ContentDigest(ours) }
        let conflict = layout.conflict(at: .now)
        do {
            try fileSystem.publish(displaced, as: conflict)
        } catch {
            Log.store.fault("couldn't rename another program's version of book.json", error.logMetadata)
            guard case .file? = try? fileSystem.item(at: displaced.url) else { return refusal(.changed) }
            return .externallyModified(.keptAsConflict(fileName: displaced.url.lastPathComponent))
        }
        Log.store.fault("another program changed book.json during a save; kept its version separately")
        return .externallyModified(.keptAsConflict(fileName: conflict.lastPathComponent))
    }

    private static func writeNewFile(_ data: Data, at url: URL, _ fileSystem: any FileSystem)
        throws(FileSystemError)
    {
        let temporary = try fileSystem.writeTemporary(data, for: url, permissionsFrom: url)
        defer { fileSystem.discard(temporary.url) }
        try fileSystem.publish(temporary, as: url)
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

    private static func load(_ layout: PackageLayout, _ fileSystem: any FileSystem) throws(LoadProblem) -> (
        Book, Data
    ) {
        guard layout.hasPackageExtension else { throw .missingPackageExtension }
        let unreadable = LoadProblem.unreadable
        switch try wrapping(
            unreadable, { () throws(FileSystemError) in try fileSystem.item(at: layout.root) })
        {
        case nil: throw .notFound
        case .file, .symbolicLink, .other: throw .notADirectory
        case .directory: break
        }
        switch try wrapping(
            unreadable, { () throws(FileSystemError) in try fileSystem.item(at: layout.book) })
        {
        case nil: throw .bookMissing
        case .directory, .symbolicLink, .other: throw .bookNotAFile
        case .file: break
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
        return (book, data)
    }

    private static func existingBackups(_ layout: PackageLayout, _ fileSystem: any FileSystem) -> [Backup] {
        BackupSlot.allCases.compactMap { slot in
            guard case .file(let metadata, _) = try? fileSystem.item(at: layout.backup(slot)) else {
                return nil
            }
            return Backup(slot: slot, modified: metadata.modified)
        }
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
