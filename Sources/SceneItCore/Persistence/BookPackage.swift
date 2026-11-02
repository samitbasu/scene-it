import CryptoKit
import Foundation
import Synchronization

/// An open `.sceneit` package, editable: creates, opens and saves `book.md`, rotating
/// `book.md.bak1…3` on each save that changes it.
///
/// It remembers a digest of the `book.md` it last read or wrote, and won't silently save
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

    static let emptyArchiveIndex = ArchiveIndexFormat.serialize(ArchiveIndex())

    /// A new package holding an empty book: no scenes, as PLAN §4.2 allows.
    /// `book.md` is written last, so a package left half-made by a failure won't open.
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
            data = try BookFormat.verifiedSerialization(of: book)
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

    /// Reads and parses `book.md` (the parse never fails; see `BookFormat`), then locks the book for
    /// editing; if it can't, the book opens read-only. A failure writes nothing and holds no
    /// lock. A success writes nothing but `.lock` (created empty, and where the `flock` can't
    /// be trusted, given a `LockRecord`).
    ///
    /// The lock is taken after the read, so a book that won't load gains no `.lock`. If
    /// `book.md` changed in between, it's read again under the lock.
    ///
    /// A book whose parse made new error entries opens read-only with `.repairedOnOpen`
    /// (ADR 0024), and one in a newer format with `.newerFormat` (book format §10 Q7); neither
    /// takes the lock. `defaults` supplies what the file leaves out.
    ///
    /// The lock belongs to the package, not the process: opening a book that this process
    /// already has open gives `.readOnly(_, .openElsewhere)`. To open it again (ADR 0018's
    /// "Open Other Version"), reuse the existing package or release it first.
    public static func open(
        at url: URL, onLockRecord policy: LockRecordPolicy = .respect, defaults: ParseDefaults = .system,
        fileSystem: any FileSystem = LocalFileSystem()
    ) throws(LoadError) -> OpenedBook {
        try open(at: url, onLockRecord: policy, defaults: defaults, fileSystem: fileSystem, opener: .current)
    }

    static func open(
        at url: URL, onLockRecord policy: LockRecordPolicy, defaults: ParseDefaults,
        fileSystem: any FileSystem, opener: Opener
    ) throws(LoadError) -> OpenedBook {
        let layout = PackageLayout(root: url)
        var read = try load(layout, defaults, fileSystem)
        if let reason = read.readOnlyReason { return readOnly(read, layout, reason) }
        switch access(layout, fileSystem, policy, opener) {
        case .editing(let lock):
            if (try? fileSystem.read(layout.book)) != read.data {
                Log.store.info("book.md changed while the book was being locked; reading it again")
                read = try load(layout, defaults, fileSystem)
            }
            let package = BookPackage(
                layout: layout, fileSystem: fileSystem, lastSeen: ContentDigest(read.data), lock: lock)
            if let reason = read.readOnlyReason {
                // Dropping `package` releases the lock: a book that opens read-only holds none.
                return readOnly(read, layout, reason)
            }
            Log.store.info(
                "opened a book",
                ["bytes": .bytes(Int64(read.data.count)), "scenes": .count(read.parsed.book.scenes.count)])
            return .editing(EditableBook(package: package, book: read.parsed.book))
        case .readOnly(let reason):
            return readOnly(read, layout, reason)
        }
    }

    private static func readOnly(_ read: ReadBook, _ layout: PackageLayout, _ reason: ReadOnlyReason)
        -> OpenedBook
    {
        Log.store.info(
            "opened a book read-only",
            [
                "bytes": .bytes(Int64(read.data.count)), "scenes": .count(read.parsed.book.scenes.count),
                "reason": .symbol(reason.logSymbol),
            ])
        return .readOnly(ReadOnlyBook(layout: layout, book: read.parsed.book), reason)
    }

    /// The bytes of `book.md` and what they parsed to.
    private struct ReadBook {
        let data: Data
        let parsed: ParsedBook

        /// Why the contents alone make the book read-only. A newer format can't be made
        /// editable, so it wins over a repair.
        var readOnlyReason: ReadOnlyReason? {
            if parsed.isNewerThanSupported, let format = parsed.declaredFormat { return .newerFormat(format) }
            guard parsed.wasRepaired else { return nil }
            return .repairedOnOpen(Repair(newEntries: parsed.newEntries, original: data))
        }
    }

    // MARK: Make Editable (ADR 0024)

    /// Make Editable's first step: writes the bytes a repaired book was read from, exactly as
    /// they were read, to a new `book.md.original-<UTC time>.md` in its package, flushed to the
    /// drive. It never replaces a file, and nothing ever removes the one it writes.
    ///
    /// The bytes are the ones the open parsed, never a second read of `book.md`, so what's
    /// kept is exactly what the writer was shown repaired.
    public static func keepOriginal(
        of book: ReadOnlyBook, _ repair: Repair, now: Date = .now,
        fileSystem: any FileSystem = LocalFileSystem()
    ) throws(FileSystemError) -> KeptOriginal {
        let layout = book.layout
        let temporary = try fileSystem.writeTemporary(
            repair.original, for: layout.original(at: now, attempt: 1), permissionsFrom: layout.book)
        let kept: URL?
        do {
            kept = try fileSystem.publishUnderFreeName(temporary) { layout.original(at: now, attempt: $0) }
        } catch {
            fileSystem.discard(temporary.url)
            throw error
        }
        guard let kept else {
            fileSystem.discard(temporary.url)
            throw FileSystemError(
                .publish, layout.original(at: now, attempt: freeNameAttempts), .alreadyExists)
        }
        Log.store.info(
            "kept the original of a book repaired as it opened",
            ["bytes": .bytes(Int64(repair.original.count))])
        return KeptOriginal(url: kept, book: book, original: ContentDigest(repair.original))
    }

    /// Make Editable's second step: locks the book for editing, as `open` does. `book.md`
    /// isn't read again: the book is the one shown read-only, and the package takes the kept
    /// original as what it last read, so a save finds any change since then and stops
    /// (ADR 0018). If the lock can't be had, the book stays read-only for that reason.
    public static func edit(
        _ kept: KeptOriginal, onLockRecord policy: LockRecordPolicy = .respect,
        fileSystem: any FileSystem = LocalFileSystem()
    ) -> OpenedBook {
        edit(kept, onLockRecord: policy, fileSystem: fileSystem, opener: .current)
    }

    static func edit(
        _ kept: KeptOriginal, onLockRecord policy: LockRecordPolicy, fileSystem: any FileSystem,
        opener: Opener
    ) -> OpenedBook {
        let layout = kept.book.layout
        switch access(layout, fileSystem, policy, opener) {
        case .editing(let lock):
            Log.store.info("made a repaired book editable")
            let package = BookPackage(
                layout: layout, fileSystem: fileSystem, lastSeen: kept.original, lock: lock)
            return .editing(EditableBook(package: package, book: kept.book.book))
        case .readOnly(let reason):
            Log.store.info(
                "couldn't make a repaired book editable", ["reason": .symbol(reason.logSymbol)])
            return .readOnly(kept.book, reason)
        }
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

    /// Writes `book` unless `book.md` already holds exactly its encoding.
    ///
    /// The backup policy is ADR 0019: another program's version is never replaced unless it's
    /// safely in `bak1`; this package's own previous save is replaced even if it couldn't be
    /// backed up, and the outcome says so. When this throws, `book.md` is unchanged.
    ///
    /// A save that writes also clears away stray temporary files (`StrayTemporaryFiles`),
    /// never failing because of them.
    public func save(
        _ book: Book, onExternalChange policy: ExternalChangePolicy = .refuse
    ) throws(SaveError) -> SaveOutcome {
        let data: Data
        do {
            data = try BookFormat.verifiedSerialization(of: book)
        } catch {
            Log.store.fault("the serialized book failed verification", ["error": .error(LoggedError(error))])
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
            StrayTemporaryFiles(packageRoot: layout, fileSystem: fileSystem).sweep(now: .now)
            return .saved(backups, PublishedBook(data: data))
        }
    }

    /// What `book.md` holds now, and whose it is.
    private struct Current {
        let data: Data
        let owner: Owner
    }

    private enum Owner {
        /// The bytes are this package's own last read or write.
        case ours
        case theirs
    }

    /// `nil` if `book.md` was removed and `policy` allows recreating it.
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
        Log.store.error("refused to save over a book.md changed by another program")
        return .externallyModified(change)
    }

    /// The refusal for a `book.md` that changed during the save, naming what's there now.
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
    /// happens before any rename. Then the renames: the backup rotation, then `book.md`.
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

    /// Replaces `book.md` with `replacement` (which holds `data`) only if it still holds
    /// `expected` (or, for `nil`, nothing), and disposes of `replacement`.
    ///
    /// With `exchange`, the check happens after the swap: if the displaced file isn't
    /// `expected`, another program renamed a new version into place after `readCurrent`, and
    /// it's swapped back. That closes the window for writers that rename into place, as sync
    /// services and most editors do. A writer that already had `book.md` open and edits it
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

    /// `book.md` now holds `published` and the other program's version sits at the temporary
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
                    "another program changed book.md during a save; kept its version separately")
                return .externallyModified(.keptAsConflict(fileName: conflict.lastPathComponent))
            }
        } catch {
            Log.store.fault("couldn't rename another program's version of book.md", error.logMetadata)
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

    private static func load(_ layout: PackageLayout, _ defaults: ParseDefaults, _ fileSystem: any FileSystem)
        throws(LoadError) -> ReadBook
    {
        let data: Data
        do {
            data = try read(layout, fileSystem)
        } catch {
            let backups = existingBackups(layout, fileSystem)
            Log.store.error(
                "couldn't open a book",
                ["problem": .symbol(error.logSymbol), "backups": .count(backups.count)])
            throw LoadError(package: layout.root, problem: error, backups: backups)
        }
        return ReadBook(data: data, parsed: defaults.parse(data))
    }

    private static func read(_ layout: PackageLayout, _ fileSystem: any FileSystem) throws(LoadProblem)
        -> Data
    {
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
        case nil:
            if case .file? = try? fileSystem.item(at: layout.legacyBook) { throw .legacyJSONBook }
            throw .bookMissing
        case .directory, .symbolicLink, .other: throw .bookNotAFile
        case .file: break
        }
        return try wrapping(unreadable) { () throws(FileSystemError) in try fileSystem.read(layout.book) }
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

/// The verified bytes a save just put in `book.md`. Only `BookPackage` makes one, so a
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

/// Why a book opened read-only. `ReadOnlyWording` has the message for each.
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
    /// Parsing `book.md` made new error entries: the file was damaged or hand-edited, and the
    /// book shown is a repair of it (ADR 0024). Make Editable (`BookPackage.keepOriginal`,
    /// then `edit`) keeps the original and opens it for editing.
    case repairedOnOpen(Repair)
    /// `book.md` says it's in this newer format, which this version would save as its own,
    /// losing what it doesn't understand (book format §10 Q7). There's no way to edit it here.
    case newerFormat(FormatVersion)

    var logSymbol: StaticString {
        switch self {
        case .openElsewhere: "openElsewhere"
        case .openOnAnotherMac: "openOnAnotherMac"
        case .openInAnotherProcess: "openInAnotherProcess"
        case .lockUnavailable: "lockUnavailable"
        case .repairedOnOpen: "repairedOnOpen"
        case .newerFormat: "newerFormat"
        }
    }
}

/// What a parse repaired in `book.md` as the book opened, and the bytes it read.
public struct Repair: Hashable, Sendable {
    /// The error entries the parse made, in the Errors tab's order (`ParsedBook.newEntries`).
    public let newEntries: [ErrorEntry]
    /// Exactly the bytes that were parsed: what Make Editable keeps.
    let original: Data
}

/// A repaired book whose original bytes are safely in its package (ADR 0024). Only
/// `BookPackage.keepOriginal` makes one, so only a book whose original is kept can be edited
/// through `BookPackage.edit`.
public struct KeptOriginal: Sendable {
    /// The `book.md.original-<UTC time>.md` holding the original.
    public let url: URL
    let book: ReadOnlyBook
    let original: ContentDigest

    fileprivate init(url: URL, book: ReadOnlyBook, original: ContentDigest) {
        self.url = url
        self.book = book
        self.original = original
    }
}
