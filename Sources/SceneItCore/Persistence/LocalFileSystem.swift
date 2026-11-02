import Foundation

/// `FileSystem` over POSIX calls, with writes that are atomic and durable: the data is
/// flushed to the drive (`F_FULLFSYNC`) before the rename that publishes it, and the
/// directory is flushed after.
public struct LocalFileSystem: FileSystem {
    public init() {}

    public func item(at url: URL) throws(FileSystemError) -> FileItem? {
        var info = stat()
        guard (url.withUnsafeFileSystemRepresentation { stat($0!, &info) }) == 0 else {
            let code = errno
            // ENOTDIR: a component of the path is a file, so nothing can be at `url`.
            if code == ENOENT || code == ENOTDIR { return nil }
            throw FileSystemError(.inspect, url, Self.cause(code))
        }
        return Self.item(info)
    }

    public func read(_ file: URL) throws(FileSystemError) -> Data {
        do {
            return try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw FileSystemError(.read, file, .notFound)
        } catch {
            throw FileSystemError(.read, file, .other(error.localizedDescription))
        }
    }

    public func writeAtomically(_ data: Data, to file: URL) throws(FileSystemError) -> FileStamp {
        let directory = file.deletingLastPathComponent()
        let temporary = directory.appending(
            path: ".\(file.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        let stamp: FileStamp
        do {
            stamp = try Self.writeDurably(data, toNewFile: temporary)
            try Self.rename(temporary, over: file)
        } catch {
            if (temporary.withUnsafeFileSystemRepresentation { unlink($0!) }) != 0 && errno != ENOENT {
                Log.store.error(
                    "couldn't remove a temporary file after a failed write", ["errno": .count(Int(errno))])
            }
            throw FileSystemError(.write, file, error.cause)
        }
        Self.flushDirectory(directory)
        return stamp
    }

    public func move(_ source: URL, over destination: URL) throws(FileSystemError) {
        do {
            try Self.rename(source, over: destination)
        } catch {
            throw FileSystemError(.move, source, error.cause)
        }
    }

    public func createDirectory(at url: URL) throws(FileSystemError) {
        guard (url.withUnsafeFileSystemRepresentation { mkdir($0!, 0o755) }) == 0 else {
            throw FileSystemError(.createDirectory, url, Self.cause(errno))
        }
    }

    private static func writeDurably(_ data: Data, toNewFile file: URL) throws(FileSystemError) -> FileStamp {
        let descriptor = file.withUnsafeFileSystemRepresentation {
            open($0!, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else { throw FileSystemError(.write, file, cause(errno)) }
        defer { close(descriptor) }
        try writeAll(data, to: descriptor, file: file)
        try flushToDrive(descriptor, file: file)
        var info = stat()
        guard fstat(descriptor, &info) == 0, case .file(let stamp) = item(info) else {
            throw FileSystemError(.write, file, cause(errno))
        }
        return stamp
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, file: URL) throws(FileSystemError) {
        let failure: Int32? = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return nil
        }
        if let failure { throw FileSystemError(.write, file, cause(failure)) }
    }

    /// `fsync` on macOS only hands the data to the drive, which may keep it in a volatile
    /// cache; `F_FULLFSYNC` also flushes that cache. Some file systems (SMB, some FUSE)
    /// don't support it, so fall back to `fsync` there.
    private static func flushToDrive(_ descriptor: Int32, file: URL) throws(FileSystemError) {
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw FileSystemError(.write, file, cause(errno))
        }
    }

    /// Makes the rename durable. A failure here can't be reported as a failed write, because
    /// the new file is already in place.
    private static func flushDirectory(_ directory: URL) {
        let descriptor = directory.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else {
            Log.store.error("couldn't open a directory to flush a rename", ["errno": .count(Int(errno))])
            return
        }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0 && fsync(descriptor) != 0 {
            Log.store.error(
                "couldn't flush a directory; a rename may not be durable yet", ["errno": .count(Int(errno))])
        }
    }

    private static func rename(_ source: URL, over destination: URL) throws(FileSystemError) {
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in Darwin.rename(from!, to!) }
        }
        guard result == 0 else { throw FileSystemError(.move, source, cause(errno)) }
    }

    private static func item(_ info: stat) -> FileItem {
        switch info.st_mode & S_IFMT {
        case S_IFREG: .file(FileStamp(size: info.st_size, modified: info.st_mtimespec))
        case S_IFDIR: .directory
        default: .other
        }
    }

    private static func cause(_ code: Int32) -> FileSystemError.Cause {
        switch code {
        case ENOENT: .notFound
        case EEXIST: .alreadyExists
        default: .other(String(cString: strerror(code)))
        }
    }
}
