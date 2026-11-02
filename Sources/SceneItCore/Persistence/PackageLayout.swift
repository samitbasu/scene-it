import Foundation

/// Where everything lives inside a `.sceneit` package (PLAN §5.1, ADR 0004, 0005 and 0022).
public struct PackageLayout: Hashable, Sendable {
    public static let pathExtension = "sceneit"
    public static let bookFileName = "book.md"
    /// Where a build before format 2 (ADR 0022) kept the book. Nothing reads it: a package
    /// holding only this fails to open (`LoadProblem.legacyJSONBook`).
    public static let legacyBookFileName = "book.json"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var hasPackageExtension: Bool {
        root.pathExtension.caseInsensitiveCompare(Self.pathExtension) == .orderedSame
    }

    public var book: URL { file(Self.bookFileName, in: root) }
    public var legacyBook: URL { file(Self.legacyBookFileName, in: root) }
    public var archive: URL { root.appending(path: "Archive", directoryHint: .isDirectory) }
    public var archiveIndex: URL { file("index.md", in: archive) }
    /// Tiered snapshots (ADR 0005), distinct from the rotated `book.md.bak1…3`.
    public var snapshots: URL { root.appending(path: "Backups", directoryHint: .isDirectory) }
    /// The book's id, which names its folder in the external mirror (ADR 0005).
    public var bookID: URL { file("book-id", in: snapshots) }

    /// Locked while the book is open for editing (ADR 0020). Never book data: nothing reads it
    /// but the lock, and it's not in `Backups/` or `Archive/`, so no snapshot or listing sees it.
    public var lock: URL { file(".lock", in: root) }

    public func backup(_ slot: BackupSlot) -> URL {
        file(slot.fileName, in: root)
    }

    public func filedCopy(_ number: FiledCopyNumber) -> URL {
        file(number.fileName, in: archive)
    }

    /// Where a version of `book.md` that another program wrote during a save is kept:
    /// `book.md.conflict-<UTC time>`, then `-2`, `-3`, … for later attempts in the same second.
    public func conflict(at date: Date, attempt: Int) -> URL {
        file("\(Self.bookFileName).conflict-\(Self.stamp(date, attempt))", in: root)
    }

    /// Where Make Editable keeps the bytes of a book that was repaired as it opened (ADR 0024):
    /// `book.md.original-<UTC time>.md`, then `-2`, `-3`, … before `.md` for later attempts in
    /// the same second. Nothing rotates, prunes or sweeps it: it's not a `BackupSlot`, a
    /// `SnapshotName` or a temporary file's name.
    public func original(at date: Date, attempt: Int) -> URL {
        file("\(Self.bookFileName).original-\(Self.stamp(date, attempt)).md", in: root)
    }

    /// Whether `fileName` is a name `original(at:attempt:)` writes.
    static func isOriginal(_ fileName: some StringProtocol) -> Bool {
        let prefix = "\(bookFileName).original-"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".md") else { return false }
        let stamp = fileName.dropFirst(prefix.count).dropLast(".md".count)
        let parts = stamp.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let date = UTCStamp.date(from: parts[0]) else { return false }
        let attempt = parts.count == 2 ? Int(parts[1]) ?? 0 : 1
        let name = PackageLayout(root: URL(filePath: "/")).original(at: date, attempt: attempt)
            .lastPathComponent
        return attempt >= 1 && fileName.utf8.elementsEqual(name.utf8)
    }

    /// Where a stray temporary file in the package's root holding a version found nowhere
    /// else in the package is kept.
    public func recovered(modified date: Date, attempt: Int) -> URL {
        Self.recovered(in: root, modified: date, attempt: attempt)
    }

    /// Where a stray temporary file in `folder` holding a version kept nowhere else is kept:
    /// `book.md.recovered-<UTC time>.md` in `folder`, the time being the file's last
    /// modification, then `-2`, `-3`, … before `.md` for later attempts with the same second.
    /// It's never a `SnapshotName`, so pruning never removes it.
    static func recovered(in folder: URL, modified date: Date, attempt: Int) -> URL {
        folder.appending(
            path: "\(bookFileName).recovered-\(stamp(date, attempt)).md", directoryHint: .notDirectory)
    }

    private static func stamp(_ date: Date, _ attempt: Int) -> String {
        UTCStamp.string(for: date) + (attempt > 1 ? "-\(attempt)" : "")
    }

    private func file(_ name: String, in directory: URL) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }
}

/// One of the rotated copies of `book.md`, newest first.
public enum BackupSlot: Int, CaseIterable, Hashable, Sendable, CustomStringConvertible {
    case bak1 = 1
    case bak2, bak3

    public var fileName: String { "\(PackageLayout.bookFileName).bak\(rawValue)" }
    public var description: String { fileName }
}

/// A filed copy in `Archive/`: `save0001.md`, `save0002.md`, … (PLAN §5.5, book format §8),
/// with at least four digits. Only the names `fileName` writes are filed copies, so each copy
/// has exactly one name.
public struct FiledCopyNumber: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: Int

    /// `nil` for a negative number.
    public init?(_ value: Int) {
        guard value >= 0 else { return nil }
        self.value = value
    }

    /// `nil` unless `fileName` is exactly what `fileName` writes for some number.
    public init?(fileName: some StringProtocol) {
        guard fileName.hasPrefix("save"), fileName.hasSuffix(".md") else { return nil }
        let digits = fileName.dropFirst("save".count).dropLast(".md".count)
        guard digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let value = Int(digits),
            let number = FiledCopyNumber(value), number.fileName == fileName
        else { return nil }
        self = number
    }

    public var fileName: String {
        let digits = String(value)
        return "save" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits + ".md"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    public var description: String { fileName }
}
