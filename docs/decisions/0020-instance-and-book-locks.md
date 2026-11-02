# 0020 — One app instance, one writer per book

**Status:** Accepted (2026-11-01). Supersedes the "lock against a 2nd writer: not chosen" note in [0005](0005-backups.md).

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
