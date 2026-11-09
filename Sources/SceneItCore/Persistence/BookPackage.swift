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
    /// Released when the last reference to this package is dropped.
    private let lock: HeldLock

    private init(layout: PackageLayout, fileSystem: any FileSystem, lastSeen: ContentDigest, lock: HeldLock) {
        self.layout = layout
        self.fileSystem = fileSystem
        self.lastSeen = Mutex(lastSeen)
        self.lock = lock
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
        let lock: HeldLock
        switch HeldLock.take(layout.lock, fileSystem, .respect, opener) {
        case .held(let held):
            lock = held
        case .readOnly(let reason):
            if case .lockUnavailable(let error) = reason { throw .fileSystem(error) }
            throw .alreadyExists(url)
        }
        do {
            try fileSystem.createDirectory(at: layout.archive)
            try GuardedWrite.writeNewFile(emptyArchiveIndex, at: layout.archiveIndex, fileSystem)
            try fileSystem.createDirectory(at: layout.snapshots)
            try GuardedWrite.writeNewFile(data, at: layout.book, fileSystem)
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
        switch HeldLock.take(layout.lock, fileSystem, policy, opener) {
        case .held(let lock):
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
        let layout: PackageLayout
        let data: Data
        let parsed: ParsedBook

        /// Why the contents alone make the book read-only. A newer format can't be made
        /// editable, so it wins over a repair.
        var readOnlyReason: ReadOnlyReason? {
            if parsed.isNewerThanSupported, let format = parsed.declaredFormat { return .newerFormat(format) }
            guard parsed.wasRepaired else { return nil }
            return .repairedOnOpen(
                .book(
                    BookRepair(file: layout, book: parsed.book, newEntries: parsed.newEntries, original: data)
                ))
        }
    }

    // MARK: Make Editable (ADR 0024)

    /// Make Editable's first step: writes the bytes a repaired book was read from, exactly as
    /// they were read, to a new `book.md.original-<UTC time>.md` in its package, flushed to the
    /// drive. It never replaces a file, and nothing ever removes the one it writes.
    ///
    /// The bytes are the ones the open parsed, never a second read of `book.md`, so what's
    /// kept is exactly what the writer was shown repaired, in the package it came from.
    public static func keepOriginal(
        of repair: BookRepair, now: Date = .now, fileSystem: any FileSystem = LocalFileSystem()
    ) throws(FileSystemError) -> KeptOriginal {
        let kept = try GuardedWrite.keepOriginal(
            repair.original, of: repair.file.saved, now: now, fileSystem: fileSystem)
        Log.store.info(
            "kept the original of a book repaired as it opened",
            ["bytes": .bytes(Int64(repair.original.count))])
        return KeptOriginal(url: kept, repair: repair)
    }

    /// Make Editable's second step: locks the book for editing, as `open` does. `book.md`
    /// isn't read again: the book is the one shown read-only, and the package takes the kept
    /// original as what it last read, so a save finds any change since then and stops
    /// (ADR 0018).
    ///
    /// It consumes `kept`, so one kept original makes one editable package. If the lock can't
    /// be had, it hands `kept` back with the reason, for another try.
    public static func edit(
        _ kept: consuming KeptOriginal, onLockRecord policy: LockRecordPolicy = .respect,
        fileSystem: any FileSystem = LocalFileSystem()
    ) -> MadeEditable {
        edit(kept, onLockRecord: policy, fileSystem: fileSystem, opener: .current)
    }

    static func edit(
        _ kept: consuming KeptOriginal, onLockRecord policy: LockRecordPolicy, fileSystem: any FileSystem,
        opener: Opener
    ) -> MadeEditable {
        let repair = kept.repair
        let layout = repair.file
        switch HeldLock.take(layout.lock, fileSystem, policy, opener) {
        case .held(let lock):
            Log.store.info("made a repaired book editable")
            let package = BookPackage(
                layout: layout, fileSystem: fileSystem, lastSeen: ContentDigest(repair.original),
                lock: lock)
            return .editing(EditableBook(package: package, book: repair.book))
        case .readOnly(let reason):
            Log.store.info(
                "couldn't make a repaired book editable", ["reason": .symbol(reason.logSymbol)])
            return .readOnly(kept, reason)
        }
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
            try save(data, policy, &lastSeen)
        }
    }

    private func save(_ data: Data, _ policy: ExternalChangePolicy, _ lastSeen: inout ContentDigest)
        throws(SaveError) -> SaveOutcome
    {
        let backups: BackupStatus
        switch try GuardedWrite(layout: layout.saved, fileSystem: fileSystem).save(data, policy, &lastSeen) {
        case .unchanged:
            Log.store.debug("book unchanged; nothing saved")
            return .unchanged
        case .written(let status):
            backups = status
        }
        Log.store.info("saved the book", ["bytes": .bytes(Int64(data.count))])
        StrayTemporaryFiles(packageRoot: layout, fileSystem: fileSystem).sweep(now: .now)
        StrayTemporaryFiles(archiveOf: layout, fileSystem: fileSystem).sweep(now: .now)
        return .saved(backups, PublishedBook(data: data))
    }

    // MARK: The archive (PLAN §5.5)

    /// File a copy (PLAN §7.1): saves `book` (refusing another program's version, as autosave
    /// does), checks that `book.md` now holds exactly its verified bytes, and files those bytes
    /// as the next `Archive/saveNNNN.md` (`Archive.file`). No save can run in between.
    public func fileCopy(
        of book: Book, as record: FilingRecord, pending: [FiledCopyNumber: PendingRecord] = [:]
    ) throws(FilingFailure) -> FiledBook {
        let data: Data
        do {
            data = try BookFormat.verifiedSerialization(of: book)
        } catch {
            throw .save(.encoding(error))
        }
        return try lastSeen.withLock { (lastSeen) throws(FilingFailure) -> FiledBook in
            let saved: SaveOutcome
            do throws(SaveError) {
                saved = try save(data, .refuse, &lastSeen)
            } catch {
                throw .save(error)
            }
            let current: Data
            do throws(FileSystemError) {
                current = try fileSystem.read(layout.book)
            } catch {
                throw .fileSystem(error)
            }
            guard current == data else { throw .bookChangedOnDisk }
            let outcome = try Archive(layout: layout, fileSystem: fileSystem).file(
                data, as: record, pending: pending)
            return FiledBook(saved: saved, outcome: outcome)
        }
    }

    /// Reconciles `Archive/` with its index (PLAN §5.5), locking any filed copy that isn't
    /// and saving the index if it changes: this package holds the book's lock. `pending`
    /// gives sections for filed copies whose filing couldn't save theirs.
    public func reconcileArchive(pending: [FiledCopyNumber: PendingRecord] = [:]) -> ReconciledArchive {
        Archive(layout: layout, fileSystem: fileSystem).reconcile(.writable, pending: pending)
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
        let parsed = defaults.parse(data)
        if parsed.wasRepaired, case .file? = try? fileSystem.item(at: layout.legacyBook) {
            Log.store.info("a book.md that needed repairs has a JSON book from before format 2 beside it")
        }
        return ReadBook(layout: layout, data: data, parsed: parsed)
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

/// The verified bytes a save just put in `book.md`. Only `BookPackage` makes one, so a
/// snapshot can't hold anything else.
public struct PublishedBook: Hashable, Sendable {
    let data: Data

    fileprivate init(data: Data) {
        self.data = data
    }
}

/// What `BookPackage.fileCopy` did: the save that came first, and the filing.
public struct FiledBook: Sendable {
    public let saved: SaveOutcome
    public let outcome: FilingOutcome
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

    public var layout: PackageLayout {
        switch self {
        case .editing(let editable): editable.package.layout
        case .readOnly(let readOnly, _): readOnly.layout
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

    /// What the File Cabinet lists, read and reconciled without writing anything. `pending`
    /// gives sections for filed copies whose filing couldn't save theirs.
    public func reconcileArchive(
        pending: [FiledCopyNumber: PendingRecord] = [:], fileSystem: any FileSystem = LocalFileSystem()
    ) -> ReconciledArchive {
        Archive(layout: layout, fileSystem: fileSystem).reconcile(.readOnly, pending: pending)
    }
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
    /// A review file says it's in this newer review format (review format §3.2): the same, for
    /// a review.
    case newerReviewFormat(FormatVersion)

    var logSymbol: StaticString {
        switch self {
        case .openElsewhere: "openElsewhere"
        case .openOnAnotherMac: "openOnAnotherMac"
        case .openInAnotherProcess: "openInAnotherProcess"
        case .lockUnavailable: "lockUnavailable"
        case .repairedOnOpen: "repairedOnOpen"
        case .newerFormat: "newerFormat"
        case .newerReviewFormat: "newerReviewFormat"
        }
    }
}

/// A file a parse repaired as it opened (ADR 0024): where it is, what it shows, the entries the
/// parse made, and the bytes it read. Only an open makes one, so the four always belong together,
/// and Make Editable keeps the bytes beside the file they came from.
public struct RepairOf<File: Hashable & Sendable>: Hashable, Sendable {
    public let file: File
    public let book: Book
    /// The error entries the parse made, in the Errors tab's order (`ParsedBook.newEntries`).
    public let newEntries: [ErrorEntry]
    /// Exactly the bytes that were parsed: what Make Editable keeps.
    let original: Data
}

public typealias BookRepair = RepairOf<PackageLayout>
/// A review file's repair (ADR 0042), which keeps its originals in the review's own folder.
public typealias ReviewRepair = RepairOf<ReviewPlace>

/// A book's or a review's repair: each kind is kept and made editable by its own code, which
/// takes only its own kind.
public enum Repair: Hashable, Sendable {
    case book(BookRepair)
    case review(ReviewRepair)

    public var book: Book {
        switch self {
        case .book(let repair): repair.book
        case .review(let repair): repair.book
        }
    }

    public var newEntries: [ErrorEntry] {
        switch self {
        case .book(let repair): repair.newEntries
        case .review(let repair): repair.newEntries
        }
    }
}

/// A repaired file whose original bytes are safely kept (ADR 0024). Only Make Editable's first
/// step makes one, and its second consumes it: it can't be copied, so one kept original makes at
/// most one editable file.
public struct KeptOriginalOf<File: Hashable & Sendable>: ~Copyable, Sendable {
    /// The `<name>.original-<UTC time>.md` holding the original.
    public let url: URL
    let repair: RepairOf<File>
}

/// A book's kept original, in its package.
public typealias KeptOriginal = KeptOriginalOf<PackageLayout>
/// A review's kept original, in the review's folder.
public typealias KeptReviewOriginal = KeptOriginalOf<ReviewPlace>

/// What `BookPackage.edit` did with a kept original.
public enum MadeEditable: ~Copyable, Sendable {
    case editing(EditableBook)
    /// The lock couldn't be had; the kept original comes back for another try.
    case readOnly(KeptOriginal, ReadOnlyReason)

    /// The editable book, if there is one; consumes this.
    public consuming func editable() -> EditableBook? {
        switch consume self {
        case .editing(let editable): editable
        case .readOnly: nil
        }
    }

    /// The kept original handed back for another try, if the lock couldn't be had; consumes this.
    public consuming func keptOriginal() -> KeptOriginal? {
        switch consume self {
        case .editing: nil
        case .readOnly(let kept, _): kept
        }
    }

    /// Why the book is still read-only, if it is.
    public var readOnlyReason: ReadOnlyReason? {
        switch self {
        case .editing: nil
        case .readOnly(_, let reason): reason
        }
    }
}
