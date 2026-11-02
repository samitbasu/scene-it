import Foundation

/// An open `.sceneit` package: creates, opens and saves `book.json`, rotating
/// `book.json.bak1…3` on each save that changes it.
///
/// It remembers the stamp of the `book.json` it last read or wrote, and refuses to save
/// over a `book.json` that has changed since.
public struct BookPackage: Sendable {
    public let layout: PackageLayout
    private let fileSystem: any FileSystem
    private var lastSeen: FileStamp

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
            _ = try fileSystem.writeAtomically(emptyArchiveIndex, to: layout.archiveIndex)
            try fileSystem.createDirectory(at: layout.snapshots)
            let stamp = try fileSystem.writeAtomically(data, to: layout.book)
            return OpenedBook(
                package: BookPackage(layout: layout, fileSystem: fileSystem, lastSeen: stamp), book: book)
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
            let (book, stamp) = try load(layout, fileSystem)
            Log.store.info(
                "opened a book", ["bytes": .bytes(stamp.size), "scenes": .count(book.scenes.count)])
            return OpenedBook(
                package: BookPackage(layout: layout, fileSystem: fileSystem, lastSeen: stamp), book: book)
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
    /// On any error `book.json` is unchanged. The only backup a failed save can cost is
    /// the oldest, `bak3`, which this save was about to retire anyway.
    public mutating func save(_ book: Book) throws(SaveError) -> SaveOutcome {
        let data: Data
        do {
            data = try BookCoding.encode(book)
        } catch {
            Log.store.error(
                "refused to save a book that doesn't encode", ["error": .error(LoggedError(error))])
            throw .encoding(.rejected(error))
        }
        return try save(encoded: data)
    }

    mutating func save(encoded data: Data) throws(SaveError) -> SaveOutcome {
        do {
            try Self.verify(data)
        } catch {
            Log.store.fault("the encoded book failed verification", ["error": .error(LoggedError(error))])
            throw .encoding(error)
        }
        let current = try readCurrentIfUnmodified()
        if current == data {
            Log.store.debug("book unchanged; nothing saved")
            return .unchanged
        }
        do {
            try backUp(current)
            lastSeen = try fileSystem.writeAtomically(data, to: layout.book)
        } catch {
            Log.store.error("couldn't save the book", error.logMetadata)
            throw .fileSystem(error)
        }
        Log.store.info("saved the book", ["bytes": .bytes(lastSeen.size)])
        return .saved
    }

    private func readCurrentIfUnmodified() throws(SaveError) -> Data {
        let item = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
            try fileSystem.item(at: layout.book)
        }
        guard item == .file(lastSeen) else {
            Log.store.error("refused to save over a book.json changed by another program")
            throw .externallyModified
        }
        return try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
            try fileSystem.read(layout.book)
        }
    }

    /// Shifts the backups down one slot and copies `current` into `bak1`. Every step is a
    /// rename or an atomic write, and `book.json` itself is never moved.
    private func backUp(_ current: Data) throws(FileSystemError) {
        let bak1 = layout.backup(.bak1)
        if try fileSystem.item(at: bak1) != nil {
            // A save that failed after this step leaves bak1 equal to book.json; shifting
            // again on the retry would push a real backup out for a duplicate.
            if try fileSystem.read(bak1) == current { return }
            let bak2 = layout.backup(.bak2)
            if try fileSystem.item(at: bak2) != nil {
                try fileSystem.move(bak2, over: layout.backup(.bak3))
            }
            try fileSystem.move(bak1, over: bak2)
        }
        _ = try fileSystem.writeAtomically(current, to: bak1)
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
    /// save report `externallyModified` instead of silently overwriting it.
    private static func load(
        _ layout: PackageLayout, _ fileSystem: any FileSystem
    ) throws(LoadProblem) -> (Book, FileStamp) {
        guard layout.hasPackageExtension else { throw .missingPackageExtension }
        let unreadable = LoadProblem.unreadable
        switch try wrapping(
            unreadable, { () throws(FileSystemError) in try fileSystem.item(at: layout.root) })
        {
        case nil: throw .notFound
        case .file, .other: throw .notADirectory
        case .directory: break
        }
        let stamp: FileStamp
        switch try wrapping(
            unreadable, { () throws(FileSystemError) in try fileSystem.item(at: layout.book) })
        {
        case nil: throw .bookMissing
        case .directory, .other: throw .bookNotAFile
        case .file(let bookStamp): stamp = bookStamp
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
        return (book, stamp)
    }

    private static func existingBackups(_ layout: PackageLayout, _ fileSystem: any FileSystem) -> [Backup] {
        BackupSlot.allCases.compactMap { slot in
            guard case .file(let stamp) = try? fileSystem.item(at: layout.backup(slot)) else { return nil }
            return Backup(slot: slot, modified: stamp.modified)
        }
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
    public var package: BookPackage
    public let book: Book
}

public enum SaveOutcome: Hashable, Sendable {
    case saved
    /// `book.json` already held exactly this book, so nothing was written or rotated.
    case unchanged
}
