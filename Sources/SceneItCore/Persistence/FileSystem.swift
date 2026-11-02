import Foundation

/// The file operations persistence uses. `LocalFileSystem` is the real one; tests wrap it
/// to inject faults.
public protocol FileSystem: Sendable {
    /// `nil` when nothing is at `url`. Follows symbolic links.
    func item(at url: URL) throws(FileSystemError) -> FileItem?

    func read(_ file: URL) throws(FileSystemError) -> Data

    /// Replaces `file` so that after a crash it holds either its old contents or `data`,
    /// never a mix, and returns the stamp of the file now holding `data`.
    func writeAtomically(_ data: Data, to file: URL) throws(FileSystemError) -> FileStamp

    /// Renames `source` to `destination` in one step, replacing anything already there.
    func move(_ source: URL, over destination: URL) throws(FileSystemError)

    /// Creates one directory; its parent must exist. Throws `.alreadyExists` if anything is at `url`.
    func createDirectory(at url: URL) throws(FileSystemError)
}

public enum FileItem: Hashable, Sendable {
    case file(FileStamp)
    case directory
    /// A device, socket or pipe: never read as a book.
    case other
}

/// What identifies one version of a file without reading it: its size and modification time.
public struct FileStamp: Hashable, Sendable {
    public let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    init(size: Int64, modified: timespec) {
        self.size = size
        modifiedSeconds = modified.tv_sec
        modifiedNanoseconds = modified.tv_nsec
    }

    public var modified: Date {
        Date(timeIntervalSince1970: TimeInterval(modifiedSeconds) + TimeInterval(modifiedNanoseconds) / 1e9)
    }
}

public struct FileSystemError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Operation: String, Hashable, Sendable {
        case inspect, read, write, move
        case createDirectory = "create a directory"
    }

    public enum Cause: Hashable, Sendable, CustomStringConvertible {
        case notFound
        case alreadyExists
        case other(String)

        public var description: String {
            switch self {
            case .notFound: "no such file or directory"
            case .alreadyExists: "it already exists"
            case .other(let reason): reason
            }
        }
    }

    public let operation: Operation
    public let path: String
    public let cause: Cause

    public init(_ operation: Operation, _ url: URL, _ cause: Cause) {
        self.operation = operation
        path = url.path(percentEncoded: false)
        self.cause = cause
    }

    public var description: String {
        "couldn't \(operation.rawValue) \(path): \(cause)"
    }

    /// The operation and cause, without the path (which can contain a book's title).
    var logMetadata: LogMetadata {
        ["operation": .symbol(operation.logSymbol), "cause": .symbol(cause.logSymbol)]
    }
}

extension FileSystemError.Operation {
    var logSymbol: StaticString {
        switch self {
        case .inspect: "inspect"
        case .read: "read"
        case .write: "write"
        case .move: "move"
        case .createDirectory: "createDirectory"
        }
    }
}

extension FileSystemError.Cause {
    var logSymbol: StaticString {
        switch self {
        case .notFound: "notFound"
        case .alreadyExists: "alreadyExists"
        case .other: "other"
        }
    }
}
