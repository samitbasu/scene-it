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
        return Self.item(info)
    }

    private static func item(_ info: stat) -> FileItem {
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            let modified = info.st_mtimespec
            let metadata = FileMetadata(
                size: info.st_size,
                modified: Date(
                    timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec)
                        / 1e9),
                fileNumber: UInt64(info.st_ino))
            return .file(metadata, protection: protection(info))
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    public func open(_ file: URL) throws(FileSystemError) -> OpenFile {
        let descriptor = file.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw FileSystemError(.read, file, .init(errno: errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw FileSystemError(.inspect, file, .init(errno: code))
        }
        return OpenFile(url: file, descriptor: descriptor, item: Self.item(info))
    }

    public func read(_ file: URL) throws(FileSystemError) -> Data {
        let descriptor = file.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw FileSystemError(.read, file, .init(errno: errno)) }
        defer { close(descriptor) }
        do {
            return try Self.readAll(from: descriptor)
        } catch {
            throw FileSystemError(.read, file, error)
        }
    }

    public func writeTemporary(
        _ data: Data, for destination: URL, permissionsFrom model: URL
    ) throws(FileSystemError) -> TemporaryFile {
        let url = destination.deletingLastPathComponent().appending(
            path: TemporaryFile.name(for: destination.lastPathComponent, id: UUID()),
            directoryHint: .notDirectory)
        let descriptor = url.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        }
        guard descriptor >= 0 else { throw FileSystemError(.write, destination, .init(errno: errno)) }
        defer { close(descriptor) }
        do throws(FileSystemError.Cause) {
            try Self.writeAll(data, to: descriptor)
            Self.copyMode(of: model, to: descriptor)
            try Self.flushToDrive(descriptor)
            return TemporaryFile(url: url)
        } catch {
            Self.removeLoggingFailure(url)
            throw FileSystemError(.write, destination, error)
        }
    }

    /// `RENAME_EXCL` makes "must not exist" part of the rename. Volumes that don't declare it
    /// (FAT, exFAT) get a check followed by a plain rename, which leaves a tiny window.
    public func publish(_ temporary: TemporaryFile, as destination: URL) throws(FileSystemError) {
        do throws(FileSystemError.Cause) {
            if Self.volume(of: destination, declares: .exclusiveRename) {
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
        guard Self.volume(of: destination, declares: .swapRename) else {
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
        Self.removeLoggingFailure(file)
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

    public func contents(of directory: URL) throws(FileSystemError) -> [DirectoryEntry] {
        guard let stream = (directory.withUnsafeFileSystemRepresentation { opendir($0!) }) else {
            throw FileSystemError(.list, directory, .init(errno: errno))
        }
        defer { closedir(stream) }
        var entries: [DirectoryEntry] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw FileSystemError(.list, directory, .init(errno: errno)) }
                return entries
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name != "." && name != ".." else { continue }
            let kind = try kind(of: entry.pointee.d_type, at: directory.appending(path: name))
            entries.append(DirectoryEntry(name: name, kind: kind))
        }
    }

    public func remove(_ file: URL) throws(FileSystemError) {
        guard (file.withUnsafeFileSystemRepresentation { unlink($0!) }) == 0 else {
            throw FileSystemError(.remove, file, .init(errno: errno))
        }
    }

    /// The file number is the inode; `st_dev` isn't used because it can change between mounts.
    /// Both `stat` and the resource lookup follow a link, so both describe the same target.
    /// The lookup uses a fresh `URL`, because Foundation caches resource values on a `URL`.
    public func identity(of url: URL) throws(FileSystemError) -> FileIdentity? {
        var info = stat()
        guard (url.withUnsafeFileSystemRepresentation { stat($0!, &info) }) == 0 else {
            throw FileSystemError(.inspect, url, .init(errno: errno))
        }
        let fresh = URL(filePath: url.path(percentEncoded: false))
        let values: URLResourceValues
        do {
            values = try fresh.resourceValues(forKeys: [.volumeUUIDStringKey])
        } catch {
            throw FileSystemError(.inspect, url, Self.cause(of: error))
        }
        guard let volume = values.volumeUUIDString else { return nil }
        return FileIdentity(volume: volume, file: UInt64(info.st_ino))
    }

    public func lock(_ file: URL) -> LockAttempt {
        ExclusiveFileLock.acquire(file)
    }

    /// Asks about the directory holding `url`, so `url` itself needn't exist yet.
    public func locality(of url: URL) -> VolumeLocality {
        let fresh = URL(filePath: url.deletingLastPathComponent().path(percentEncoded: false))
        let values = try? fresh.resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal == true ? .local : .network
    }

    private static func cause(of error: any Error) -> FileSystemError.Cause {
        let bridged = error as NSError
        let posix =
            bridged.domain == NSPOSIXErrorDomain
            ? bridged : bridged.userInfo[NSUnderlyingErrorKey] as? NSError
        guard let posix, posix.domain == NSPOSIXErrorDomain else { return .io }
        return FileSystemError.Cause(errno: Int32(posix.code))
    }

    /// Some volumes don't fill in `d_type`; those entries are inspected one by one.
    private func kind(of type: UInt8, at url: URL) throws(FileSystemError) -> DirectoryEntry.Kind {
        switch Int32(type) {
        case DT_REG: return .file
        case DT_DIR: return .directory
        case DT_LNK: return .symbolicLink
        case DT_UNKNOWN:
            switch try item(at: url) {
            case .file?: return .file
            case .directory?: return .directory
            case .symbolicLink?: return .symbolicLink
            case .other?, nil: return .other
            }
        default: return .other
        }
    }

    /// Reads from the descriptor's offset to the end of the file.
    static func readAll(from descriptor: Int32) throws(FileSystemError.Cause) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[..<count])
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw errnoCause()
            }
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws(FileSystemError.Cause) {
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
    static func flushToDrive(_ descriptor: Int32) throws(FileSystemError.Cause) {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard [ENOTSUP, ENOTTY, EINVAL].contains(errno) else { throw errnoCause() }
        guard fsync(descriptor) == 0 else { throw errnoCause() }
    }

    /// Makes a rename or creation in the directory durable. A failure is logged, not thrown:
    /// the change is already visible, so reporting the operation as failed would be false.
    private static func flushDirectory(containing url: URL) {
        let directory = url.deletingLastPathComponent()
        let descriptor = directory.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_RDONLY | O_CLOEXEC)
        }
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

    private enum RenameCapability {
        case swapRename, exclusiveRename
    }

    private static func volume(of url: URL, declares capability: RenameCapability) -> Bool {
        let directory = url.deletingLastPathComponent()
        switch capability {
        case .swapRename:
            let values = try? directory.resourceValues(forKeys: [.volumeSupportsSwapRenamingKey])
            return values?.volumeSupportsSwapRenaming == true
        case .exclusiveRename:
            let values = try? directory.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey])
            return values?.volumeSupportsExclusiveRenaming == true
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

    private static func removeLoggingFailure(_ url: URL) {
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
