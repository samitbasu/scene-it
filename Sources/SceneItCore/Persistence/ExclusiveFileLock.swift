import Foundation

/// An exclusive `flock(2)` on a file, held for as long as this value lives (ADR 0020).
///
/// The kernel ties the lock to the open file, not to the process's good behaviour: closing
/// the descriptor, or the process dying in any way, releases it. So there's never a stale
/// lock to break.
///
/// Non-copyable, so exactly one value owns the descriptor and dropping it releases the lock,
/// like Rust's `fd_lock::RwLockWriteGuard`. A class would also close on `deinit`, but every
/// copied reference would extend the lock's life invisibly.
///
/// The file is opened without `O_TRUNC` and is never deleted. Deleting a lock file races:
/// a process that opened the old file before the `unlink` can lock it while a newcomer
/// creates and locks a new file under the same name, and both believe they hold the lock.
public struct ExclusiveFileLock: ~Copyable, Sendable {
    public let file: URL
    let descriptor: Int32

    private init(file: URL, descriptor: Int32) {
        self.file = file
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Creates `file` if it's missing. Never waits: a lock held by another open file
    /// (in this process or another) is `.heldElsewhere`.
    ///
    /// `O_CLOEXEC` keeps a child process from inheriting the descriptor, which would hold
    /// the lock for as long as the child lives. `O_NONBLOCK` keeps a named pipe planted at
    /// `file` from blocking the open; anything but a regular file is refused.
    public static func acquire(_ file: URL) -> LockAttempt {
        let descriptor = file.withUnsafeFileSystemRepresentation {
            open($0!, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o644)
        }
        guard descriptor >= 0 else { return .failed(FileSystemError(.lock, file, .init(errno: errno))) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            return .failed(FileSystemError(.lock, file, .init(errno: code)))
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            return .failed(FileSystemError(.lock, file, .other(.EFTYPE)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            return code == EWOULDBLOCK
                ? .heldElsewhere : .failed(FileSystemError(.lock, file, .init(errno: code)))
        }
        return .acquired(ExclusiveFileLock(file: file, descriptor: descriptor))
    }

    /// Releases the lock now rather than when the value goes out of scope.
    public consuming func release() {}

    /// What's in the locked file, read through the locked descriptor.
    public func contents() throws(FileSystemError) -> Data {
        do {
            try rewind()
            return try LocalFileSystem.readAll(from: descriptor)
        } catch {
            throw FileSystemError(.read, file, error)
        }
    }

    /// Replaces what's in the locked file in place, and flushes it to the drive.
    public func replaceContents(with data: Data) throws(FileSystemError) {
        do throws(FileSystemError.Cause) {
            guard ftruncate(descriptor, 0) == 0 else { throw .init(errno: errno) }
            try rewind()
            try LocalFileSystem.writeAll(data, to: descriptor)
            try LocalFileSystem.flushToDrive(descriptor)
        } catch {
            throw FileSystemError(.write, file, error)
        }
    }

    private func rewind() throws(FileSystemError.Cause) {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw .init(errno: errno) }
    }
}

public enum LockAttempt: ~Copyable, Sendable {
    case acquired(ExclusiveFileLock)
    /// Another open file holds the lock: another process, or another `acquire` in this one.
    case heldElsewhere
    /// The file couldn't be opened or locked: a read-only volume, no permission, something
    /// other than a file in the way, or a volume that doesn't support `flock`.
    case failed(FileSystemError)
}
