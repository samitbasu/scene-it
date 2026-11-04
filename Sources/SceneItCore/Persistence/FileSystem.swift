import Foundation

/// The file operations persistence uses. `LocalFileSystem` is the real one; tests wrap it
/// to inject faults.
///
/// A filed copy (`PackageLayout.isFiledCopy`) is never changed through it: `remove`, `move`
/// and `exchange` refuse one with `.filedCopy`, and `publish` never replaces anything.
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

    /// Opens `file` for reading. Refuses to follow a symbolic link at `file`, and never waits
    /// for a writer if a pipe is there.
    func open(_ file: URL) throws(FileSystemError) -> OpenFile

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

    /// The entries of `directory`, in no particular order, without `.` and `..`.
    func contents(of directory: URL) throws(FileSystemError) -> [DirectoryEntry]

    /// Removes the file or symbolic link at `file`; never a directory. Not flushed: after a
    /// power loss the file may still be there.
    func remove(_ file: URL) throws(FileSystemError)

    /// Sets the immutable flag on the file at `file` (`chflags uchg`, Finder's "Locked"), never
    /// following a link. APFS, HFS+, FAT and exFAT all keep it on macOS 27; a volume that has
    /// no such flag (some network shares) refuses, and one could accept the call without
    /// keeping the flag: `item(at:)` tells which.
    func makeImmutable(_ file: URL) throws(FileSystemError)

    /// Removes the empty directory at `directory` (`rmdir`); never follows a link.
    func removeDirectory(_ directory: URL) throws(FileSystemError)

    /// Which file or directory is at `url`, whatever its path: `nil` if its volume has no
    /// UUID to tell it apart. Follows a symbolic link at `url`. Throws, rather than returning
    /// `nil`, when the volume's UUID can't be read, so a failure isn't taken for "no UUID".
    func identity(of url: URL) throws(FileSystemError) -> FileIdentity?

    /// An exclusive, non-blocking `flock` on `file`, created empty if it's missing.
    func lock(_ file: URL) -> LockAttempt

    /// Whether a `flock` on `url`'s volume also keeps out other Macs.
    func locality(of url: URL) -> VolumeLocality
}

public enum VolumeLocality: Hashable, Sendable {
    /// Every process that can open the volume's files runs on this Mac, so its kernel
    /// enforces every `flock`.
    case local
    /// A network volume (SMB, NFS, AFP), or one whose locality couldn't be read: another Mac
    /// can open the same files, and won't see a `flock` taken here (ADR 0020).
    case network
}

/// A volume's UUID and the file number within it. Unlike a path, it doesn't change when a
/// directory is renamed or moved within its volume, and a copy gets a different one.
public struct FileIdentity: Hashable, Sendable, Codable {
    public let volume: String
    public let file: UInt64

    public init(volume: String, file: UInt64) {
        self.volume = volume
        self.file = file
    }
}

public struct DirectoryEntry: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case file, directory, symbolicLink, other
    }

    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
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
    /// The inode: which file this is on its volume, whatever its name.
    public let fileNumber: UInt64
}

/// A file opened for reading. `item` describes the file that was opened, which the path
/// may no longer name.
public final class OpenFile {
    public let item: FileItem
    private let url: URL
    private let descriptor: Int32

    init(url: URL, descriptor: Int32, item: FileItem) {
        self.url = url
        self.descriptor = descriptor
        self.item = item
    }

    deinit {
        close(descriptor)
    }

    /// The whole file, from the start.
    public func read() throws(FileSystemError) -> Data {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw FileSystemError(.read, url, .init(errno: errno))
        }
        do {
            return try LocalFileSystem.readAll(from: descriptor)
        } catch {
            throw FileSystemError(.read, url, error)
        }
    }
}

extension FileSystem {
    /// Renames `temporary` to the first of `name(1)`, `name(2)`, … that's free, never
    /// replacing anything; `nil` if all `freeNameAttempts` are taken.
    func publishUnderFreeName(_ temporary: TemporaryFile, _ name: (Int) -> URL) throws(FileSystemError)
        -> URL?
    {
        for attempt in 1...freeNameAttempts {
            let destination = name(attempt)
            do {
                try publish(temporary, as: destination)
                return destination
            } catch  where error.cause == .alreadyExists {
                continue
            }
        }
        return nil
    }
}

let freeNameAttempts = 100

public enum WriteProtection: Hashable, Sendable {
    /// The owner's write permission is off (`chmod a-w`).
    case readOnly
    /// Finder's "Locked" (the immutable flag) or the append-only flag.
    case locked
}

/// A durable file under a hidden name, waiting to be published or discarded.
public struct TemporaryFile: Hashable, Sendable {
    public let url: URL

    /// `.<destination>.<UUID>.tmp`, the UUID in upper case: the name `LocalFileSystem` gives
    /// the temporary file for `destination`.
    static func name(for destination: String, id: UUID) -> String {
        ".\(destination).\(id.uuidString).tmp"
    }

    /// The `destination` that `name(for:id:)` made `name` from; `nil` for any other name.
    static func destination(ofName name: String) -> Substring? {
        let pattern = /\.(.+)\.[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.tmp/
        return name.wholeMatch(of: pattern.matchingSemantics(.unicodeScalar))?.output.1
    }
}

public struct FileSystemError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Operation: String, Hashable, Sendable {
        case inspect, read, write, publish, exchange, move, list, remove, lock
        case createDirectory = "create a directory"
        case makeImmutable = "set the locked flag on"
    }

    public enum Cause: Error, Hashable, Sendable, CustomStringConvertible {
        case notFound
        case alreadyExists
        case noSpace
        case permissionDenied
        case readOnlyVolume
        case unsupported
        case io
        /// The file is a filed copy, which nothing may change or remove (PLAN §5.5).
        case filedCopy
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
            case .filedCopy: "it's a filed copy, which is never changed"
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
        case .list: "list"
        case .remove: "remove"
        case .lock: "lock"
        case .createDirectory: "createDirectory"
        case .makeImmutable: "makeImmutable"
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
        case .filedCopy: "filedCopy"
        case .other: "other"
        }
    }
}
