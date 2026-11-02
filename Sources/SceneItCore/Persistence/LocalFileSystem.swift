import Foundation

/// `FileSystem` over POSIX calls. Data is flushed to the drive (`F_FULLFSYNC`) before the
/// rename that publishes it, and the directory is flushed after.
public struct LocalFileSystem: FileSystem {
    public init() {}

    public func item(at url: URL) throws(FileSystemError) -> FileItem? {
        var info = stat()
        guard (url.withUnsafeFileSystemRepresentation { lstat($0!, &info) }) == 0 else {
            let code = errno
            // ENOTDIR: a component of the path is a file, so nothing can be at `url`.
            if code == ENOENT || code == ENOTDIR { return nil }
            throw FileSystemError(.inspect, url, .init(errno: code))
        }
        return Self.item(info)
    }

    public func read(_ file: URL) throws(FileSystemError) -> Data {
        let descriptor = file.withUnsafeFileSystemRepresentation {
            open($0!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw FileSystemError(.read, file, .init(errno: errno)) }
        defer { close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[..<count])
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw FileSystemError(.read, file, .init(errno: errno))
            }
        }
    }

    public func writeTemporary(
        _ data: Data, for destination: URL, permissionsFrom model: URL
    ) throws(FileSystemError) -> TemporaryFile {
        let url = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        let descriptor = url.withUnsafeFileSystemRepresentation {
            open($0!, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        }
        guard descriptor >= 0 else { throw FileSystemError(.write, destination, .init(errno: errno)) }
        defer { close(descriptor) }
        do throws(FileSystemError.Cause) {
            try Self.writeAll(data, to: descriptor)
            Self.copyMode(of: model, to: descriptor)
            try Self.flushToDrive(descriptor)
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw Self.errnoCause() }
            return TemporaryFile(url: url, stamp: FileStamp(info))
        } catch {
            Self.remove(url)
            throw FileSystemError(.write, destination, error)
        }
    }

    public func publish(_ temporary: TemporaryFile, as destination: URL) throws(FileSystemError) {
        do {
            try Self.rename(temporary.url, over: destination)
        } catch {
            throw FileSystemError(.publish, destination, error)
        }
        Self.flushDirectory(containing: destination)
    }

    public func discard(_ temporary: TemporaryFile) {
        Self.remove(temporary.url)
    }

    public func move(_ source: URL, over destination: URL) throws(FileSystemError) {
        do {
            try Self.rename(source, over: destination)
        } catch {
            throw FileSystemError(.move, source, error)
        }
    }

    public func createDirectory(at url: URL) throws(FileSystemError) {
        guard (url.withUnsafeFileSystemRepresentation { mkdir($0!, 0o755) }) == 0 else {
            throw FileSystemError(.createDirectory, url, .init(errno: errno))
        }
        Self.flushDirectory(containing: url)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws(FileSystemError.Cause) {
        let failure: Int32? = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written == 0 {
                    return EIO
                } else if errno != EINTR {
                    return errno
                }
            }
            return nil
        }
        if let failure { throw FileSystemError.Cause(errno: failure) }
    }

    /// Like Foundation's atomic write, a replacement keeps the permissions of the file it
    /// replaces. Volumes without POSIX permissions (FAT, exFAT) may refuse; that's not worth
    /// failing a save for.
    private static func copyMode(of model: URL, to descriptor: Int32) {
        var info = stat()
        guard (model.withUnsafeFileSystemRepresentation { lstat($0!, &info) }) == 0,
            info.st_mode & S_IFMT == S_IFREG
        else { return }
        if fchmod(descriptor, info.st_mode & 0o7777) != 0 {
            Log.store.error("couldn't copy a file's permissions to its replacement", ["errno": .errno(errno)])
        }
    }

    /// `fsync` on macOS only hands the data to the drive, which may keep it in a volatile
    /// cache; `F_FULLFSYNC` also flushes that cache. File systems that don't implement it
    /// (SMB, some FUSE volumes) report ENOTSUP, ENOTTY or EINVAL, and get `fsync` instead.
    private static func flushToDrive(_ descriptor: Int32) throws(FileSystemError.Cause) {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard [ENOTSUP, ENOTTY, EINVAL].contains(errno) else { throw errnoCause() }
        guard fsync(descriptor) == 0 else { throw errnoCause() }
    }

    /// Makes a rename or creation in the directory durable. A failure is logged, not thrown:
    /// the change is already visible, so reporting the operation as failed would be false.
    private static func flushDirectory(containing url: URL) {
        let directory = url.deletingLastPathComponent()
        let descriptor = directory.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else {
            Log.store.error("couldn't open a directory to flush it", ["errno": .errno(errno)])
            return
        }
        defer { close(descriptor) }
        do {
            try flushToDrive(descriptor)
        } catch {
            Log.store.error(
                "couldn't flush a directory; a change in it may not be durable yet",
                ["cause": .symbol(error.logSymbol)])
        }
    }

    private static func rename(_ source: URL, over destination: URL) throws(FileSystemError.Cause) {
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in Darwin.rename(from!, to!) }
        }
        guard result == 0 else { throw errnoCause() }
    }

    private static func remove(_ url: URL) {
        if (url.withUnsafeFileSystemRepresentation { unlink($0!) }) != 0 && errno != ENOENT {
            Log.store.error("couldn't remove a temporary file", ["errno": .errno(errno)])
        }
    }

    private static func errnoCause() -> FileSystemError.Cause {
        FileSystemError.Cause(errno: errno)
    }

    private static func item(_ info: stat) -> FileItem {
        switch info.st_mode & S_IFMT {
        case S_IFREG: .file(FileStamp(info), protection(info))
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .other
        }
    }

    private static func protection(_ info: stat) -> WriteProtection {
        if info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { return .locked }
        if info.st_mode & S_IWUSR == 0 { return .readOnly }
        return .writable
    }
}
