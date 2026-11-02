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

    public func backup(_ slot: BackupSlot) -> URL {
        file(slot.fileName, in: root)
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
