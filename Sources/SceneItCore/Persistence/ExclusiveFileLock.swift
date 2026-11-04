import Foundation

/// An exclusive `flock(2)` on a file, held for as long as this value lives (ADR 0020).
///
/// The kernel ties the lock to the open file, not to the process's good behaviour: dropping
/// this value, or the process dying in any way, releases it. So there's never a stale
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
    public let enforcement: LockEnforcement
    let descriptor: Int32

    private init(file: URL, descriptor: Int32, enforcement: LockEnforcement) {
        self.file = file
        self.descriptor = descriptor
        self.enforcement = enforcement
    }

    /// Unlocks before closing: `close` releases the `flock` only if it drops the last
    /// reference to the open file, and a process being spawned on another thread holds a
    /// copy of every descriptor until its `exec` closes the `O_CLOEXEC` ones.
    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Creates `file` if it's missing. Never waits: a lock held by another open file
    /// (in this process or another) is `.heldElsewhere`.
    ///
    /// `O_CLOEXEC` keeps a child process from inheriting the descriptor, which would hold
    /// the lock for as long as the child lives. `O_NONBLOCK` keeps a named pipe planted at
    /// `file` from blocking the open; anything but a regular file is refused. A file that
    /// can't be opened for writing is locked through a read-only descriptor, which `flock`
    /// accepts; only `replaceContents` then fails.
    public static func acquire(_ file: URL) -> LockAttempt {
        acquire(file, locking: { flock($0, LOCK_EX | LOCK_NB) })
    }

    /// `locking` stands in for `flock` in tests, to simulate a volume that doesn't support it.
    static func acquire(_ file: URL, locking: (Int32) -> Int32) -> LockAttempt {
        var descriptor = open(file, O_RDWR | O_CREAT)
        let openError = errno
        if descriptor < 0 && openError == EACCES {
            descriptor = open(file, O_RDONLY)
        }
        guard descriptor >= 0 else { return .failed(FileSystemError(.lock, file, .init(errno: openError))) }
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
        guard locking(descriptor) == 0 else {
            let code = errno
            switch code {
            case EWOULDBLOCK:
                close(descriptor)
                return .heldElsewhere
            case ENOTSUP, EOPNOTSUPP:
                return .acquired(ExclusiveFileLock(file: file, descriptor: descriptor, enforcement: .none))
            default:
                close(descriptor)
                return .failed(FileSystemError(.lock, file, .init(errno: code)))
            }
        }
        return .acquired(ExclusiveFileLock(file: file, descriptor: descriptor, enforcement: .kernel))
    }

    private static func open(_ file: URL, _ flags: Int32) -> Int32 {
        file.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o644)
        }
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

    /// Replaces what's in the locked file in place, and flushes it to the drive. Writes
    /// over the old contents before truncating, so a reader never finds the file empty
    /// in between.
    public func replaceContents(with data: Data) throws(FileSystemError) {
        do throws(FileSystemError.Cause) {
            try rewind()
            try LocalFileSystem.writeAll(data, to: descriptor)
            guard ftruncate(descriptor, off_t(data.count)) == 0 else { throw .init(errno: errno) }
            try LocalFileSystem.flushToDrive(descriptor)
        } catch {
            throw FileSystemError(.write, file, error)
        }
    }

    private func rewind() throws(FileSystemError.Cause) {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw .init(errno: errno) }
    }
}

public enum LockEnforcement: Hashable, Sendable {
    /// The kernel holds the `flock`, and refuses it to every other open file.
    case kernel
    /// The volume doesn't support `flock` (NFS mounted `nolocks`, some FUSE file systems):
    /// the file is open, but nothing is locked. Only an advisory `LockRecord` can help.
    case none
}

public enum LockAttempt: ~Copyable, Sendable {
    /// Check the lock's `enforcement`: on a volume without `flock` this holds nothing.
    case acquired(ExclusiveFileLock)
    /// Another open file holds the lock: another process, or another `acquire` in this one.
    case heldElsewhere
    /// The file couldn't be opened or locked: a folder without permission to create it,
    /// something other than a file in the way, or an I/O error.
    case failed(FileSystemError)
}
