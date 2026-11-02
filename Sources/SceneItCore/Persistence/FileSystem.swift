import Foundation

/// The file operations persistence uses. `LocalFileSystem` is the real one; tests wrap it
/// to inject faults.
///
/// Writing is split in two so that every write that can fail (a full disk, an I/O error)
/// happens before anything visible changes: `writeTemporary` makes a durable copy under a
/// hidden name, and `publish` renames it into place.
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

    /// Renames `temporary` over `destination` in one step and makes the rename durable.
    func publish(_ temporary: TemporaryFile, as destination: URL) throws(FileSystemError)

    /// Removes a temporary file that won't be published. Failures are logged, not thrown.
    func discard(_ temporary: TemporaryFile)

    /// Renames `source` to `destination` in one step, replacing anything already there.
    func move(_ source: URL, over destination: URL) throws(FileSystemError)

    /// Creates one directory, durably; its parent must exist. Throws `.alreadyExists` if
    /// anything is at `url`.
    func createDirectory(at url: URL) throws(FileSystemError)
}

public enum FileItem: Hashable, Sendable {
    case file(FileStamp, WriteProtection)
    case directory
    case symbolicLink
    /// A device, socket or pipe: never read as a book.
    case other
}

public enum WriteProtection: Hashable, Sendable {
    case writable
    /// The owner's write permission is off (`chmod a-w`).
    case readOnly
    /// Finder's "Locked" (the immutable flag).
    case locked
}

/// Identifies one version of a file without reading it: its size, modification time and
/// inode number. A replaced file has a new inode even if its size and time match.
public struct FileStamp: Hashable, Sendable {
    public let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let inode: UInt64

    init(_ info: stat) {
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        inode = info.st_ino
    }

    public var modified: Date {
        Date(timeIntervalSince1970: TimeInterval(modifiedSeconds) + TimeInterval(modifiedNanoseconds) / 1e9)
    }
}

/// A durable file under a hidden name, waiting to be published or discarded.
public struct TemporaryFile: Hashable, Sendable {
    public let url: URL
    /// The stamp the file keeps once published: a rename changes neither its time nor its inode.
    public let stamp: FileStamp
}

public struct FileSystemError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Operation: String, Hashable, Sendable {
        case inspect, read, write, publish, move
        case createDirectory = "create a directory"
    }

    public enum Cause: Error, Hashable, Sendable, CustomStringConvertible {
        case notFound
        case alreadyExists
        case noSpace
        case permissionDenied
        case readOnlyVolume
        case io
        case other(POSIXErrorCode)

        public init(errno code: Int32) {
            switch code {
            case ENOENT: self = .notFound
            case EEXIST: self = .alreadyExists
            case ENOSPC, EDQUOT: self = .noSpace
            case EACCES, EPERM: self = .permissionDenied
            case EROFS: self = .readOnlyVolume
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
        case .io: "io"
        case .other: "other"
        }
    }
}
