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

    public func backup(_ slot: BackupSlot) -> URL {
        file(slot.fileName, in: root)
    }

    /// Where a version of `book.json` that another program wrote during a save is kept:
    /// `book.json.conflict-<UTC time>`, then `-2`, `-3`, … for later attempts in the same second.
    public func conflict(at date: Date, attempt: Int) -> URL {
        let stamp = date.formatted(
            .iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false)
                .timeSeparator(.omitted))
        let suffix = attempt > 1 ? "-\(attempt)" : ""
        return file("book.json.conflict-\(stamp)\(suffix)", in: root)
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
