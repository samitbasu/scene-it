import Foundation

/// The file operations persistence uses. `LocalFileSystem` is the real one; tests wrap it
/// to inject faults.
///
/// Writing is split in two so that every write that can fail (a full disk, an I/O error)
/// happens before anything visible changes: `writeTemporary` makes a durable copy under a
/// hidden name, and a rename (`publish`, `exchange` or `move`) puts it in place. Every
/// rename is durable: the directory is flushed after it.
public protocol FileSystem: Sendable {
    /// `nil` when nothing is at `url`. Doesn't follow a symbolic link at `url` itself.
    func item(at url: URL) throws(FileSystemError) -> FileItem?

    /// Refuses to follow a symbolic link at `file`.
    func read(_ file: URL) throws(FileSystemError) -> Data

    /// Writes `data` to a new hidden file next to `destination` and flushes it to the
    /// drive. The file takes the permissions of `model` if that's an existing file.
    func writeTemporary(
        _ data: Data, for destination: URL, permissionsFrom model: URL
    ) throws(FileSystemError) -> TemporaryFile

    /// Renames `temporary` to `destination`, which must not exist: throws `.alreadyExists`
    /// rather than replace anything.
    func publish(_ temporary: TemporaryFile, as destination: URL) throws(FileSystemError)

    /// Swaps `temporary` and `destination` in one step: afterwards `destination` holds the
    /// temporary file's contents, and `temporary.url` holds what `destination` held.
    /// Throws `.unsupported` on volumes that can't swap (FAT, exFAT, HFS+).
    func exchange(_ temporary: TemporaryFile, with destination: URL) throws(FileSystemError)

    /// Removes a hidden temporary file if it's still there. Failures are logged, not thrown.
    func discard(_ file: URL)

    /// Renames `source` to `destination` in one step, replacing anything already there.
    func move(_ source: URL, over destination: URL) throws(FileSystemError)

    /// Creates one directory, durably; its parent must exist. Throws `.alreadyExists` if
    /// anything is at `url`.
    func createDirectory(at url: URL) throws(FileSystemError)
}

public enum FileItem: Hashable, Sendable {
    /// `protection` is `nil` when the file can be replaced.
    case file(FileMetadata, protection: WriteProtection?)
    case directory
    case symbolicLink
    /// A device, socket or pipe: never read as a book.
    case other
}

public struct FileMetadata: Hashable, Sendable {
    public let size: Int64
    public let modified: Date
}

public enum WriteProtection: Hashable, Sendable {
    /// The owner's write permission is off (`chmod a-w`).
    case readOnly
    /// Finder's "Locked" (the immutable flag) or the append-only flag.
    case locked
}

/// A durable file under a hidden name, waiting to be published or discarded.
public struct TemporaryFile: Hashable, Sendable {
    public let url: URL
}

public struct FileSystemError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Operation: String, Hashable, Sendable {
        case inspect, read, write, publish, exchange, move
        case createDirectory = "create a directory"
    }

    public enum Cause: Error, Hashable, Sendable, CustomStringConvertible {
        case notFound
        case alreadyExists
        case noSpace
        case permissionDenied
        case readOnlyVolume
        case unsupported
        case io
        case other(POSIXErrorCode)

        public init(errno code: Int32) {
            switch code {
            case ENOENT: self = .notFound
            case EEXIST: self = .alreadyExists
            case ENOSPC, EDQUOT: self = .noSpace
            case EACCES, EPERM: self = .permissionDenied
            case EROFS: self = .readOnlyVolume
            case ENOTSUP: self = .unsupported
            case EIO: self = .io
            default: self = POSIXErrorCode(rawValue: code).map(Cause.other) ?? .io
            }
        }

        public var description: String {
            switch self {
            case .notFound: "no such file or directory"
            case .alreadyExists: "it already exists"
            case .noSpace: "the disk is full"
            case .permissionDenied: "permission denied"
            case .readOnlyVolume: "the disk is read-only"
            case .unsupported: "the disk doesn't support this operation"
            case .io: "an input/output error"
            case .other(let code): String(cString: strerror(code.rawValue))
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
        if case .other(let code) = cause {
            return ["operation": .symbol(operation.logSymbol), "errno": .errno(code.rawValue)]
        }
        return ["operation": .symbol(operation.logSymbol), "cause": .symbol(cause.logSymbol)]
    }
}

extension FileSystemError.Operation {
    var logSymbol: StaticString {
        switch self {
        case .inspect: "inspect"
        case .read: "read"
        case .write: "write"
        case .publish: "publish"
        case .exchange: "exchange"
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
        case .noSpace: "noSpace"
        case .permissionDenied: "permissionDenied"
        case .readOnlyVolume: "readOnlyVolume"
        case .unsupported: "unsupported"
        case .io: "io"
        case .other: "other"
        }
    }
}
