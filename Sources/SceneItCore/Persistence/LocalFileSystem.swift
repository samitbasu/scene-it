import Foundation

/// `FileSystem` over POSIX calls. Data is flushed to the drive (`F_FULLFSYNC`) before the
/// rename that publishes it, and the directory is flushed after every rename.
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
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            let modified = info.st_mtimespec
            let metadata = FileMetadata(
                size: info.st_size,
                modified: Date(
                    timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec)
                        / 1e9))
            return .file(metadata, protection: Self.protection(info))
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
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
            return TemporaryFile(url: url)
        } catch {
            Self.remove(url)
            throw FileSystemError(.write, destination, error)
        }
    }

    /// `RENAME_EXCL` makes "must not exist" part of the rename. Volumes that don't declare it
    /// (FAT, exFAT) get a check followed by a plain rename, which leaves a tiny window.
    public func publish(_ temporary: TemporaryFile, as destination: URL) throws(FileSystemError) {
        do throws(FileSystemError.Cause) {
            if Self.volume(of: destination, declares: .volumeSupportsExclusiveRenamingKey) {
                try Self.rename(temporary.url, to: destination, flags: UInt32(RENAME_EXCL))
            } else {
                var info = stat()
                guard (destination.withUnsafeFileSystemRepresentation { lstat($0!, &info) }) != 0 else {
                    throw .alreadyExists
                }
                try Self.rename(temporary.url, to: destination, flags: 0)
            }
        } catch {
            throw FileSystemError(.publish, destination, error)
        }
        Self.flushDirectory(containing: destination)
    }

    /// Only on volumes that declare swap support: FAT32 on macOS 27 returns success from
    /// `RENAME_SWAP` but performs a plain rename, destroying the destination.
    public func exchange(_ temporary: TemporaryFile, with destination: URL) throws(FileSystemError) {
        guard Self.volume(of: destination, declares: .volumeSupportsSwapRenamingKey) else {
            throw FileSystemError(.exchange, destination, .unsupported)
        }
        do {
            try Self.rename(temporary.url, to: destination, flags: UInt32(RENAME_SWAP))
        } catch {
            throw FileSystemError(.exchange, destination, error)
        }
        Self.flushDirectory(containing: destination)
    }

    public func discard(_ file: URL) {
        Self.remove(file)
    }

    public func move(_ source: URL, over destination: URL) throws(FileSystemError) {
        do {
            try Self.rename(source, to: destination, flags: 0)
        } catch {
            throw FileSystemError(.move, source, error)
        }
        Self.flushDirectory(containing: destination)
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

    /// Like Foundation's atomic write, a replacement keeps the permission bits of the file it
    /// replaces (not setuid, setgid or sticky, and not ACLs). Volumes without POSIX
    /// permissions (FAT, exFAT) may refuse; that's not worth failing a save for.
    private static func copyMode(of model: URL, to descriptor: Int32) {
        var info = stat()
        guard (model.withUnsafeFileSystemRepresentation { lstat($0!, &info) }) == 0,
            info.st_mode & S_IFMT == S_IFREG
        else { return }
        if fchmod(descriptor, info.st_mode & 0o777) != 0 {
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

    private static func volume(of url: URL, declares capability: URLResourceKey) -> Bool {
        let values = try? url.deletingLastPathComponent().resourceValues(forKeys: [capability])
        return switch capability {
        case .volumeSupportsSwapRenamingKey: values?.volumeSupportsSwapRenaming == true
        case .volumeSupportsExclusiveRenamingKey: values?.volumeSupportsExclusiveRenaming == true
        default: false
        }
    }

    /// `renamex_np` reports EINVAL for flags a volume doesn't support, and ENOTSUP for some;
    /// both mean `.unsupported` when flags were asked for.
    private static func rename(_ source: URL, to destination: URL, flags: UInt32) throws(FileSystemError
        .Cause)
    {
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in renamex_np(from!, to!, flags) }
        }
        guard result != 0 else { return }
        let code = errno
        if flags != 0 && (code == ENOTSUP || code == EINVAL) { throw .unsupported }
        throw FileSystemError.Cause(errno: code)
    }

    private static func remove(_ url: URL) {
        if (url.withUnsafeFileSystemRepresentation { unlink($0!) }) != 0 && errno != ENOENT {
            Log.store.error("couldn't remove a temporary file", ["errno": .errno(errno)])
        }
    }

    private static func errnoCause() -> FileSystemError.Cause {
        FileSystemError.Cause(errno: errno)
    }

    private static func protection(_ info: stat) -> WriteProtection? {
        let locked = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
        if info.st_flags & locked != 0 { return .locked }
        if info.st_mode & S_IWUSR == 0 { return .readOnly }
        return nil
    }
}
