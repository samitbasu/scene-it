import Foundation

/// Where everything lives inside a `.sceneit` package (PLAN §5.1, ADR 0004 and 0005).
public struct PackageLayout: Hashable, Sendable {
    public static let pathExtension = "sceneit"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var hasPackageExtension: Bool {
        root.pathExtension.caseInsensitiveCompare(Self.pathExtension) == .orderedSame
    }

    public var book: URL { file("book.json", in: root) }
    public var archive: URL { root.appending(path: "Archive", directoryHint: .isDirectory) }
    public var archiveIndex: URL { file("index.json", in: archive) }
    /// Tiered snapshots (ADR 0005), distinct from the rotated `book.json.bak1…3`.
    public var snapshots: URL { root.appending(path: "Backups", directoryHint: .isDirectory) }
    /// The book's id, which names its folder in the external mirror (ADR 0005).
    public var bookID: URL { file("book-id", in: snapshots) }

    /// Locked while the book is open for editing (ADR 0020). Never book data: nothing reads it
    /// but the lock, and it's not in `Backups/` or `Archive/`, so no snapshot or listing sees it.
    public var lock: URL { file(".lock", in: root) }

    public func backup(_ slot: BackupSlot) -> URL {
        file(slot.fileName, in: root)
    }

    /// Where a version of `book.json` that another program wrote during a save is kept:
    /// `book.json.conflict-<UTC time>`, then `-2`, `-3`, … for later attempts in the same second.
    public func conflict(at date: Date, attempt: Int) -> URL {
        file("book.json.conflict-\(Self.stamp(date, attempt))", in: root)
    }

    /// Where a stray temporary file in the package's root holding a version found nowhere
    /// else in the package is kept.
    public func recovered(modified date: Date, attempt: Int) -> URL {
        Self.recovered(in: root, modified: date, attempt: attempt)
    }

    /// Where a stray temporary file in `folder` holding a version kept nowhere else is kept:
    /// `book.json.recovered-<UTC time>.json` in `folder`, the time being the file's last
    /// modification, then `-2`, `-3`, … before `.json` for later attempts with the same second.
    /// It's never a `SnapshotName`, so pruning never removes it.
    static func recovered(in folder: URL, modified date: Date, attempt: Int) -> URL {
        folder.appending(
            path: "book.json.recovered-\(stamp(date, attempt)).json", directoryHint: .notDirectory)
    }

    private static func stamp(_ date: Date, _ attempt: Int) -> String {
        UTCStamp.string(for: date) + (attempt > 1 ? "-\(attempt)" : "")
    }

    private func file(_ name: String, in directory: URL) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }
}

/// One of the rotated copies of `book.json`, newest first.
public enum BackupSlot: Int, CaseIterable, Hashable, Sendable, CustomStringConvertible {
    case bak1 = 1
    case bak2, bak3

    public var fileName: String { "book.json.bak\(rawValue)" }
    public var description: String { fileName }
}
