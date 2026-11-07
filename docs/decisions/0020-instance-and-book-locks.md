# 0020 — One app instance, one writer per book

**Status:** Accepted (2026-11-01). Supersedes the "lock against a 2nd writer: not chosen" note in [0005](0005-backups.md). **Amended by [0038](0038-one-book-per-process.md)** (2026-11-06): a forwarded book is opened only if the running instance has no book yet; otherwise the instance comes forward and says the open book must be closed first (nothing, if it is the open book).

## Decision
Two locks, both kernel-released `flock(2)` locks on open files, so a crash or power loss can never
leave a stale lock and the writer is never asked to "break" one:

1. **App-wide:** at launch, Scene It takes an exclusive, non-blocking `flock` on
   `~/Library/Application Support/Scene It/instance.lock`. If it's held, the new instance activates
   the running one (forwarding any book it was asked to open) and quits. This applies to any copy of
   the app, Debug or Release. **Exempt:** the XCTest host and SwiftUI previews (they never take the lock),
   so `scripts/check.sh` works while the writer has Scene It open.
2. **Per book:** opening a book for editing takes an exclusive `flock` on `<book>.sceneit/.lock`,
   held for as long as the book is open. If it's held (another user account, or an instance that got
   past the app lock), the book opens **read-only**, with a clear message saying it's open
   elsewhere. Never two writers.

## Caveat: network volumes
`flock` isn't honoured across SMB/NFS clients. On volumes where the lock can't be trusted, the
book lock also writes the holder's host, PID and time into `.lock`, as an advisory check. A different
host's live record makes the book open read-only, with an "Open Anyway" escape hatch. Detecting
"untrusted" volumes reuses the volume-capability queries from persistence.

## Learning notes
`flock` is advisory and per open file description: the lock lives as long as the fd, and the kernel
drops it when the process exits. That's the same mechanism as Rust's `fs2::FileExt::try_lock_exclusive`.

## Details settled in the implementation (#53)
- **Untrusted volumes** are those whose `volumeIsLocalKey` is false or unreadable, and those
  where `flock` fails with `ENOTSUP`/`EOPNOTSUPP` (NFS mounted `nolocks`, some FUSE file
  systems). On those, the record alone decides; the book isn't forced read-only.
- **The advisory record** (`LockRecord`: computer name, hardware UUID, user id, PID, ISO-8601
  time) never expires: a writer may keep a book open for days, and a crashed Mac's leftover
  costs one "Open Anyway". A record from this Mac blocks while its process is alive
  (`kill(pid, 0)`, where `EPERM` counts as alive) and isn't the opener's own; a dead
  process's record is a leftover and is ignored. It's cleared, while the lock is still
  held, when the book closes, if it's still ours. "Open Anyway" applies to the exact record
  the writer was shown.
- **The lock file is never deleted** (deleting races with a process about to lock it) and
  never opened with `O_TRUNC`. It's opened with `O_CLOEXEC`, so child processes don't
  inherit the lock, and released with `LOCK_UN` before `close`: a process being spawned
  holds a copy of every descriptor until its `exec`, and `close` alone wouldn't release a
  lock whose open file still has another reference (#103). A lock file without write permission is locked through a read-only
  descriptor (`flock` allows it); only the record can't be written.
- **A failed load takes no lock**: `open` reads first, then locks, so a damaged package gains
  no `.lock`. If `book.json` (`book.md` since ADR 0022) changed in between, it's read again under the lock; if it no
  longer loads, the lock is released and the load fails.
- **The app lock file holds the holder's PID**, so a second launch hands off to exactly that
  process, falling back to any other running instance with the bundle id.
- **If the app lock can't be taken** (as opposed to being held), the app runs anyway and logs
  it; each book's own lock still prevents two writers.
