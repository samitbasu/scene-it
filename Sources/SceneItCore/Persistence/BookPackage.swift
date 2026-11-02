import CryptoKit
import Foundation
import Synchronization

/// An open `.sceneit` package, editable: creates, opens and saves `book.json`, rotating
/// `book.json.bak1…3` on each save that changes it.
///
/// It remembers a digest of the `book.json` it last read or wrote, and won't silently save
/// over a different one. A class, so that two copies can't disagree about that; saves are
/// serialized by its mutex.
///
/// It holds the book's `.lock` (ADR 0020) for as long as it lives, so another `open`
/// finds the book read-only until the last reference to this package is dropped. That
/// release does file I/O (clearing a `LockRecord`, flushed to the drive), so drop the last
/// reference off the main actor.
public final class BookPackage: Sendable {
    public let layout: PackageLayout
    let fileSystem: any FileSystem
    private let lastSeen: Mutex<ContentDigest>
    private let lock: ExclusiveFileLock
    /// What this package wrote into `.lock`, where the `flock` alone can't be trusted.
    private let record: LockRecord?

    private init(
        layout: PackageLayout, fileSystem: any FileSystem, lastSeen: ContentDigest,
        lock: consuming EditingLock
    ) {
        self.layout = layout
        self.fileSystem = fileSystem
        self.lastSeen = Mutex(lastSeen)
        self.record = lock.record
        self.lock = lock.lock
    }

    /// Takes the record back out of `.lock` while the `flock` is still held. A record that
    /// isn't ours (someone chose "Open Anyway") is left alone. The file itself stays: see
    /// `ExclusiveFileLock`.
    deinit {
        guard let record, (try? lock.contents()).flatMap(LockRecord.decode) == record else { return }
        do {
            try lock.replaceContents(with: Data())
        } catch {
            Log.store.error("couldn't clear this Mac's record from a book's lock file", error.logMetadata)
        }
    }

    static let emptyArchiveIndex = Data(#"{"copies":[]}"#.utf8)

    /// A new package holding an empty book: no scenes, as PLAN §4.2 allows.
    /// `book.json` is written last, so a package left half-made by a failure won't open.
    /// The new package is locked before anything is written into it.
    public static func create(
        at url: URL, title: String, fileSystem: any FileSystem = LocalFileSystem()
    ) throws(CreateError) -> EditableBook {
        try create(at: url, title: title, fileSystem: fileSystem, opener: .current)
    }

    static func create(
        at url: URL, title: String, fileSystem: any FileSystem, opener: Opener
    ) throws(CreateError) -> EditableBook {
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
        let lock: EditingLock
        switch access(layout, fileSystem, .respect, opener) {
        case .editing(let editing):
            lock = editing
        case .readOnly(let reason):
            if case .lockUnavailable(let error) = reason { throw .fileSystem(error) }
            throw .alreadyExists(url)
        }
        do {
            try fileSystem.createDirectory(at: layout.archive)
            try writeNewFile(emptyArchiveIndex, at: layout.archiveIndex, fileSystem)
            try fileSystem.createDirectory(at: layout.snapshots)
            try writeNewFile(data, at: layout.book, fileSystem)
        } catch {
            Log.store.error("couldn't create a book package", error.logMetadata)
            throw .fileSystem(error)
        }
        let package = BookPackage(
            layout: layout, fileSystem: fileSystem, lastSeen: ContentDigest(data), lock: lock)
        return EditableBook(package: package, book: book)
    }

    /// Reads, decodes and validates `book.json`, all or nothing, then locks the book for
    /// editing; if it can't, the book opens read-only. A failure writes nothing and holds no
    /// lock. A success writes nothing but `.lock` (created empty, and where the `flock` can't
    /// be trusted, given a `LockRecord`).
    ///
    /// The lock is taken after the read, so a book that won't load gains no `.lock`. If
    /// `book.json` changed in between, it's read again under the lock.
    ///
    /// The lock belongs to the package, not the process: opening a book that this process
    /// already has open gives `.readOnly(_, .openElsewhere)`. To open it again (ADR 0018's
    /// "Open Other Version"), reuse the existing package or release it first.
    public static func open(
        at url: URL, onLockRecord policy: LockRecordPolicy = .respect,
        fileSystem: any FileSystem = LocalFileSystem()
    ) throws(LoadError) -> OpenedBook {
        try open(at: url, onLockRecord: policy, fileSystem: fileSystem, opener: .current)
    }

    static func open(
        at url: URL, onLockRecord policy: LockRecordPolicy, fileSystem: any FileSystem, opener: Opener
    ) throws(LoadError) -> OpenedBook {
        let layout = PackageLayout(root: url)
        var book: Book
        var data: Data
        do {
            (book, data) = try load(layout, fileSystem)
        } catch {
            throw loadFailure(error, layout, fileSystem)
        }
        switch access(layout, fileSystem, policy, opener) {
        case .editing(let lock):
            if (try? fileSystem.read(layout.book)) != data {
                Log.store.info("book.json changed while the book was being locked; reading it again")
                do {
                    (book, data) = try load(layout, fileSystem)
                } catch {
                    throw loadFailure(error, layout, fileSystem)
                }
            }
            Log.store.info(
                "opened a book", ["bytes": .bytes(Int64(data.count)), "scenes": .count(book.scenes.count)])
            let package = BookPackage(
                layout: layout, fileSystem: fileSystem, lastSeen: ContentDigest(data), lock: lock)
            return .editing(EditableBook(package: package, book: book))
        case .readOnly(let reason):
            Log.store.info(
                "opened a book read-only",
                [
                    "bytes": .bytes(Int64(data.count)), "scenes": .count(book.scenes.count),
                    "reason": .symbol(reason.logSymbol),
                ])
            return .readOnly(ReadOnlyBook(layout: layout, book: book), reason)
        }
    }

    private static func loadFailure(
        _ problem: LoadProblem, _ layout: PackageLayout, _ fileSystem: any FileSystem
    )
        -> LoadError
    {
        let backups = existingBackups(layout, fileSystem)
        Log.store.error(
            "couldn't open a book", ["problem": .symbol(problem.logSymbol), "backups": .count(backups.count)])
        return LoadError(package: layout.root, problem: problem, backups: backups)
    }

    private enum Access: ~Copyable {
        case editing(EditingLock)
        case readOnly(ReadOnlyReason)
    }

    /// The book's lock, and the record that tells others about it where the lock alone can't.
    private struct EditingLock: ~Copyable {
        let lock: ExclusiveFileLock
        let record: LockRecord?
    }

    private static func access(
        _ layout: PackageLayout, _ fileSystem: any FileSystem, _ policy: LockRecordPolicy, _ opener: Opener
    ) -> Access {
        let lock: ExclusiveFileLock
        switch fileSystem.lock(layout.lock) {
        case .acquired(let acquired): lock = acquired
        case .heldElsewhere: return .readOnly(.openElsewhere)
        case .failed(let error): return .readOnly(.lockUnavailable(error))
        }
        guard lock.enforcement == .none || fileSystem.locality(of: layout.lock) == .network else {
            return .editing(EditingLock(lock: lock, record: nil))
        }
        let existing = (try? lock.contents()).flatMap(LockRecord.decode)
        if let other = LockRecord.blocking(existing, opener: opener, policy: policy) {
            return .readOnly(
                other.hostID == opener.mac.id ? .openInAnotherProcess(other) : .openOnAnotherMac(other))
        }
        let ours = LockRecord(opener, since: .now)
        do {
            try lock.replaceContents(with: ours.encoded())
        } catch {
            Log.store.error(
                "couldn't record this process in a book's lock file; others may not see it's open",
                ["error": .error(LoggedError(error))])
            return .editing(EditingLock(lock: lock, record: nil))
        }
        return .editing(EditingLock(lock: lock, record: ours))
    }

    /// Writes `book` unless `book.json` already holds exactly its encoding.
    ///
    /// The backup policy is ADR 0019: another program's version is never replaced unless it's
    /// safely in `bak1`; this package's own previous save is replaced even if it couldn't be
    /// backed up, and the outcome says so. When this throws, `book.json` is unchanged.
    ///
    /// A save that writes also clears away stray temporary files (`StrayTemporaryFiles`),
    /// never failing because of them.
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
            StrayTemporaryFiles(layout: layout, fileSystem: fileSystem).sweep(now: .now)
            return .saved(backups, PublishedBook(data: data))
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
            guard policy == .recreate else { throw refusal(.removed) }
            return nil
        case .directory, .symbolicLink, .other:
            throw refusal(.notAFile)
        case .file(_, let protection):
            if let protection { throw .writeProtected(protection) }
            let data = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
                try fileSystem.read(layout.book)
            }
            let digest = ContentDigest(data)
            if digest == lastSeen { return Current(data: data, owner: .ours) }
            guard policy == .overwriteKeepingTheirsAsBackup(theirs: digest) else {
                throw refusal(.changed(theirs: digest))
            }
            return Current(data: data, owner: .theirs)
        }
    }

    private func refusal(_ change: ExternalChange) -> SaveError {
        Log.store.error("refused to save over a book.json changed by another program")
        return .externallyModified(change)
    }

    /// The refusal for a `book.json` that changed during the save, naming what's there now.
    private func changedDuringSave() -> SaveError {
        let item: FileItem?
        do {
            item = try fileSystem.item(at: layout.book)
        } catch {
            return .fileSystem(error)
        }
        switch item {
        case nil:
            return refusal(.removed)
        case .directory, .symbolicLink, .other:
            return refusal(.notAFile)
        case .file:
            do {
                return refusal(.changed(theirs: ContentDigest(try fileSystem.read(layout.book))))
            } catch {
                return .fileSystem(error)
            }
        }
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
            try replace(with: replacement, holding: data, expecting: current?.data, &lastSeen)
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

    /// Replaces `book.json` with `replacement` (which holds `data`) only if it still holds
    /// `expected` (or, for `nil`, nothing), and disposes of `replacement`.
    ///
    /// With `exchange`, the check happens after the swap: if the displaced file isn't
    /// `expected`, another program renamed a new version into place after `readCurrent`, and
    /// it's swapped back. That closes the window for writers that rename into place, as sync
    /// services and most editors do. A writer that already had `book.json` open and edits it
    /// in place can still write to the displaced file after the comparison, and that write is
    /// lost when the file is discarded. Volumes that can't swap get a re-check just before a
    /// plain rename.
    private func replace(
        with replacement: TemporaryFile, holding data: Data, expecting expected: Data?,
        _ lastSeen: inout ContentDigest
    ) throws(SaveError) {
        guard let expected else {
            do {
                return try fileSystem.publish(replacement, as: layout.book)
            } catch {
                fileSystem.discard(replacement.url)
                throw error.cause == .alreadyExists ? changedDuringSave() : .fileSystem(error)
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
            throw keepAsConflict(replacement, published: data, &lastSeen)
        }
        fileSystem.discard(replacement.url)
        throw changedDuringSave()
    }

    /// For volumes that can't swap (FAT, exFAT, HFS+). A change landing between this re-read
    /// and the rename is lost; the window is a few microseconds.
    private func replaceWithoutExchange(_ replacement: TemporaryFile, expecting expected: Data)
        throws(SaveError)
    {
        guard (try? fileSystem.read(layout.book)) == expected else {
            fileSystem.discard(replacement.url)
            throw changedDuringSave()
        }
        do {
            try fileSystem.move(replacement.url, over: layout.book)
        } catch {
            fileSystem.discard(replacement.url)
            throw .fileSystem(error)
        }
    }

    /// `book.json` now holds `published` and the other program's version sits at the temporary
    /// name, which nothing reads; give it a visible name so it isn't lost.
    ///
    /// `lastSeen` becomes the digest of what this save wrote, not of a fresh read: a third
    /// write landing now must not be mistaken for ours.
    private func keepAsConflict(
        _ displaced: TemporaryFile, published: Data, _ lastSeen: inout ContentDigest
    ) -> SaveError {
        lastSeen = ContentDigest(published)
        let now = Date.now
        do {
            if let conflict = try fileSystem.publishUnderFreeName(
                displaced, { layout.conflict(at: now, attempt: $0) })
            {
                Log.store.fault(
                    "another program changed book.json during a save; kept its version separately")
                return .externallyModified(.keptAsConflict(fileName: conflict.lastPathComponent))
            }
        } catch {
            Log.store.fault("couldn't rename another program's version of book.json", error.logMetadata)
        }
        guard case .file? = try? fileSystem.item(at: displaced.url) else { return changedDuringSave() }
        return .externallyModified(.keptAsConflict(fileName: displaced.url.lastPathComponent))
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

/// SHA-256 of a file's contents, so recognizing a version doesn't mean keeping a copy.
public struct ContentDigest: Hashable, Sendable {
    let bytes: Data

    public init(_ contents: Data) {
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

/// The verified bytes a save just put in `book.json`. Only `BookPackage` makes one, so a
/// snapshot can't hold anything else.
public struct PublishedBook: Hashable, Sendable {
    let data: Data

    fileprivate init(data: Data) {
        self.data = data
    }
}

/// A book as `open` found it. Only the editable form has a `BookPackage`, and so a way to save.
public enum OpenedBook: Sendable {
    case editing(EditableBook)
    case readOnly(ReadOnlyBook, ReadOnlyReason)

    public var book: Book {
        switch self {
        case .editing(let editable): editable.book
        case .readOnly(let readOnly, _): readOnly.book
        }
    }
}

public struct EditableBook: Sendable {
    /// Holds the book's lock until the last reference to it is dropped.
    public let package: BookPackage
    public let book: Book
}

/// A book open for reading only: there's no `BookPackage`, so nothing can save it.
public struct ReadOnlyBook: Sendable {
    public let layout: PackageLayout
    public let book: Book
}

/// Why a book opened read-only. `LockWording` has the message for each.
public enum ReadOnlyReason: Hashable, Sendable {
    /// Its `flock` is held: by this process's own package for the book, Scene It in another
    /// user account, or a copy that didn't go through the app lock. Never two writers, so
    /// there's no "Open Anyway".
    case openElsewhere
    /// Where the `flock` can't be trusted (a network volume, or one without `flock`),
    /// another Mac's `LockRecord` is in `.lock`. `LockRecordPolicy.openAnyway(record)`
    /// opens it for editing.
    case openOnAnotherMac(LockRecord)
    /// As `.openOnAnotherMac`, but the record names a live process on this Mac: another
    /// user account or another copy of Scene It, on a volume without `flock`.
    case openInAnotherProcess(LockRecord)
    /// `.lock` couldn't be created or locked: typically a read-only volume or a folder
    /// without write permission, where a save would fail anyway.
    case lockUnavailable(FileSystemError)

    var logSymbol: StaticString {
        switch self {
        case .openElsewhere: "openElsewhere"
        case .openOnAnotherMac: "openOnAnotherMac"
        case .openInAnotherProcess: "openInAnotherProcess"
        case .lockUnavailable: "lockUnavailable"
        }
    }
}
