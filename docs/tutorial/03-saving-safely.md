# 03 — Saving safely

How a book gets onto disk without ever being lost or half-loaded, explained for someone
who has written `tempfile` + `persist` in Rust.

The rules come from [WORKFLOW.md](../dev/WORKFLOW.md)'s trust section: never write
`book.json` without encode → verify → rotate → atomic write; a failed load never
half-loads or overwrites anything; refuse with a clear error rather than guess. This
chapter shows how each rule turns into code, and what each step does and doesn't
guarantee if the power goes out.

## Where the code is

Everything lives in [`Sources/SceneItCore/Persistence/`](../../Sources/SceneItCore/Persistence/):

| File | What it holds |
| --- | --- |
| [`BookPackage.swift`](../../Sources/SceneItCore/Persistence/BookPackage.swift) | create, open and save; the save pipeline |
| [`PackageLayout.swift`](../../Sources/SceneItCore/Persistence/PackageLayout.swift) | where each file lives in a `.sceneit` package; `BackupSlot` |
| [`FileSystem.swift`](../../Sources/SceneItCore/Persistence/FileSystem.swift) | the file-system protocol (the testing seam), `FileStamp`, `FileSystemError` |
| [`LocalFileSystem.swift`](../../Sources/SceneItCore/Persistence/LocalFileSystem.swift) | the real implementation: POSIX calls, `F_FULLFSYNC` |
| [`PersistenceErrors.swift`](../../Sources/SceneItCore/Persistence/PersistenceErrors.swift) | `SaveError`, `SaveOutcome`, `ExternalChangePolicy`, `CreateError`, `LoadError` |

The tests are in [`Tests/SceneItCoreTests/Persistence/`](../../Tests/SceneItCoreTests/Persistence/).

---

## 1. The package

A book is a directory named `My Novel.sceneit` that Finder shows as one document
([ADR 0004](../decisions/0004-book-is-a-package.md)):

```
My Novel.sceneit/
  book.json
  book.json.bak1 … bak3     the last three versions, newest first
  Archive/index.json        {"copies":[]} in a new book (PLAN §5.5)
  Backups/                  tiered snapshots (ADR 0005, issue #9)
```

`PackageLayout` is the one place that knows those names. Everything else asks it,
for example `layout.backup(.bak2)`. A new book is created empty, with no scenes,
which PLAN §4.2 allows (the rail's "current scene" is grayed out). `book.json` is
the last thing `create` writes, so a creation interrupted halfway leaves a package
that `open` refuses with "the package has no book.json" instead of something that
looks like a book.

`BookPackage` is a `final class`, not a struct. It remembers which `book.json` it last
read or wrote (§7), and two copies of a struct could each remember something different
and then disagree about whether the file had changed. Its state is behind a `Mutex`,
so two saves can't interleave either.

## 2. `throws` and typed errors

Chapter 00 §6 introduced typed throws. Persistence is where they pay off: the store
(#11) has to show a different message for "your book is invalid", "the disk is full",
"the file is locked" and "another program changed the file", and an exhaustive
`switch` over a typed error makes the compiler check that it handles them all. Each
entry point names its error type:

```swift
    public static func create(
        at url: URL, title: String, fileSystem: any FileSystem = LocalFileSystem()
    ) throws(CreateError) -> OpenedBook {
```

```swift
    public func save(
        _ book: Book, onExternalChange policy: ExternalChangePolicy = .refuse
    ) throws(SaveError) -> SaveOutcome {
```

A save that succeeds still has something to say, so `SaveOutcome` is `.unchanged`
or `.saved(BackupStatus)`, where `BackupStatus` is `.intact` or
`.degraded(FileSystemError)` (§4). The status bar can show all three.

File-system errors are typed down to the cause. `FileSystemError.Cause` names the
ones the store can explain (`.noSpace`, `.permissionDenied`, `.readOnlyVolume`,
`.io`, …) and keeps the rest as `.other(POSIXErrorCode)` rather than as a string.

There's no `From`, so every boundary converts by hand. When the calls in a `do`
block throw one type, the `catch` infers it. A `throw error` statement inside the
block defeats that inference: the block's type falls back to `any Error`, and the
fix is to state it with `do throws(FileSystemError) {`. `replaceBook` (§4) does that.
Where a single call has to be wrapped inline, a small generic helper does it. Its
closure needs the explicit `() throws(FileSystemError) in`, because (chapter 00 §6)
closures don't infer typed throws:

```swift
private func wrapping<T, E: Error>(
    _ wrap: (FileSystemError) -> E, _ body: () throws(FileSystemError) -> T
) throws(E) -> T {
```

```swift
        let data = try wrapping(unreadable) { () throws(FileSystemError) in try fileSystem.read(layout.book) }
```

It plays the role of Rust's `.map_err(LoadProblem::Unreadable)?`.

## 3. The save pipeline

```swift
    func save(
        encoded data: Data, onExternalChange policy: ExternalChangePolicy = .refuse
    ) throws(SaveError) -> SaveOutcome {
        do {
            try Self.verify(data)
        } catch {
            Log.store.fault("the encoded book failed verification", ["error": .error(LoggedError(error))])
            throw .encoding(error)
        }
        return try lastSeen.withLock { (lastSeen) throws(SaveError) -> SaveOutcome in
            let current = try readCurrent(&lastSeen, policy)
            if current == data {
                Log.store.debug("book unchanged; nothing saved")
                return .unchanged
            }
            let (stamp, backups) = try replaceBook(with: data, backingUp: current)
            lastSeen = KnownVersion(stamp: stamp, contents: data)
            Log.store.info("saved the book", ["bytes": .bytes(stamp.size)])
            return .saved(backups)
        }
    }
```

In order:

1. **Encode.** `save(_ book:)` calls `BookCoding.encode`, which runs the validator
   first (chapter 02 §8), so an invalid book never reaches the disk.
2. **Verify.** Decode the bytes and encode the result again, and require the *same
   bytes*:

   ```swift
           guard reencoded == data else { throw .unstable }
   ```

   Not `Book ==`: Swift's `String ==` compares canonical equivalence, so `"é"`
   written as one code point (NFC) equals `"e"` plus a combining accent (NFD). Two
   "equal" books can encode differently, and comparing values would hide exactly
   the kind of drift this step exists to catch.
3. **Check `book.json`.** Refuse a read-only or locked file (§8), and detect another
   program's changes (§7).
4. **Skip unchanged.** If `book.json` already holds these exact bytes, return
   `.unchanged` without touching anything. Autosave runs every couple of seconds;
   if it rotated each time, three idle autosaves would push every real backup out.
5. **Replace,** in two phases: write everything, then rename (§4).

Every failure is logged through `Log.store` (chapter 11) before it's thrown. The
log gets the operation and cause as fixed symbols (`operation=write cause=noSpace`),
never the path: a path contains the book's title, and the `Log` API only accepts
`StaticString` messages and `LogValue` metadata, so it couldn't carry one anyway.

## 4. Write everything, then rename

PLAN §5.4 says "rotate `bak2`→`bak3`, `bak1`→`bak2`, `book.json`→`bak1`, then write".
Done in that order, the rotation has already happened when the write fails, so a full
disk costs a backup every time. And done literally with renames, there's a moment
with no `book.json` at all.

So the save splits into two phases. **Phase 1 writes**: a durable temporary copy of
the current `book.json` (the new `bak1`) and a durable temporary copy of the new book.
Those writes are the only steps that can fail because the disk is full or a sector
is bad, and when they fail nothing visible has changed yet. **Phase 2 only renames.**
`book.json` is never moved, just replaced in one step by its new version.

```swift
    private func replaceBook(
        with data: Data, backingUp current: Data?
    ) throws(SaveError) -> (FileStamp, BackupStatus) {
        var backup: (file: TemporaryFile, bak1: Bak1)?
        do throws(FileSystemError) {
            if let current, case let bak1 = bak1Holding(current), bak1 != .holdsCurrent {
                let file = try fileSystem.writeTemporary(
                    current, for: layout.backup(.bak1), permissionsFrom: layout.book)
                backup = (file, bak1)
            }
            let replacement = try fileSystem.writeTemporary(
                data, for: layout.book, permissionsFrom: layout.book)
            let status = backup.map { rotateBackups(publishing: $0.file, over: $0.bak1) } ?? .intact
            backup = nil
            do {
                try fileSystem.publish(replacement, as: layout.book)
            } catch {
                fileSystem.discard(replacement)
                throw error
            }
            return (replacement.stamp, status)
        } catch {
            if let backup { fileSystem.discard(backup.file) }
            Log.store.error("couldn't save the book", error.logMetadata)
            throw .fileSystem(error)
        }
    }
```

The rotation is best effort:

```swift
    private func rotateBackups(publishing backup: TemporaryFile, over bak1: Bak1) -> BackupStatus {
        var failures: [FileSystemError] = []
        if bak1 == .holdsOther {
            for (source, destination) in [(BackupSlot.bak2, BackupSlot.bak3), (.bak1, .bak2)] {
                do {
                    try fileSystem.move(layout.backup(source), over: layout.backup(destination))
                } catch  where error.cause == .notFound {
                    continue
                } catch {
                    failures.append(error)
                }
            }
        }
        do {
            try fileSystem.publish(backup, as: layout.backup(.bak1))
        } catch {
            fileSystem.discard(backup)
            failures.append(error)
        }
        guard let first = failures.first else { return .intact }
        Log.store.error("couldn't rotate the backups; saving the book anyway", first.logMetadata)
        return .degraded(first)
    }
```

The details that matter:

- **Saving `book.json` comes first.** A backup slot can be damaged: a locked file, a
  directory someone created, a file iCloud evicted. None of that may stop the writer's
  work from being saved. A failed rotation step is logged, the remaining steps still
  run (the newest versions are the ones worth keeping), and the save reports
  `.saved(.degraded(error))`.
- **A missing slot absorbs the shift.** A missing `bak2` is `.notFound` and is skipped,
  so `bak3` keeps its version. A missing `bak1` means nothing shifts at all. A retry
  after a crash fills the gap instead of discarding another version.
- **`bak1 == book.json` means "already backed up".** If the final rename failed, `bak1`
  already holds the current version. Without this check, every failing autosave would
  shift again, and three of them would replace all the backups with copies of the
  current book. `bak1Holding` compares sizes before reading, and anything it can't read
  counts as different, so an unreadable `bak1` costs a rotation, never a save. The
  tests catch the regression: making `bak1Holding` always answer "different" fails the
  final-rename row.

A backup's modification time is *when that version was superseded*: the copy into
`bak1` is a new file, and renames keep it. `LoadError` lists those times.

## 5. Atomic, durable writes on APFS

### What `rename(2)` gives you

POSIX `rename` replaces the destination name in one step: any process looking at
`book.json` sees the old file or the new one, never a mix or nothing. APFS keeps that
true across a crash, because its metadata updates are copy-on-write transactions. That's
the "atomic" in atomic write: write a temporary file next to the target, then rename
it over the target.

What `rename` doesn't promise is *durability*: after a power cut, the rename may have
reached disk while the temporary file's data hadn't. That's what flushing is for.

### `fsync` isn't enough on macOS

`man 2 fcntl` says `F_FULLFSYNC` "does the same thing as fsync(2) then asks the drive to
flush all buffered data to the permanent storage device". On macOS `fsync` only hands
data to the drive, which may hold it in a volatile cache. Measured on this machine (an
Apple SSD, 1 MB files, 20 runs each): about 0.44 ms per `fsync` and 6.8 ms per
`F_FULLFSYNC`. A save does up to four (two files, and the directory after each publish), which is a fine price for a novel.

### Rust comparison

The idiomatic Rust is:

```rust
let mut tmp = tempfile::NamedTempFile::new_in(dir)?;
tmp.write_all(&bytes)?;
tmp.as_file().sync_all()?;      // F_FULLFSYNC on Apple targets
tmp.persist(&path)?;            // rename(2)
std::fs::File::open(dir)?.sync_all()?;
```

Two things here were checked in source rather than remembered: Rust's
`File::sync_all` calls `fcntl(fd, F_FULLFSYNC)` on Apple targets
(`library/std/src/sys/fs/unix.rs`, `os_fsync`), and `tempfile` 3.27's
`persist` is a plain `rename` that syncs nothing, so the explicit
`sync_all` calls are what make it durable. Our seam splits the same recipe in two:
`writeTemporary` is everything up to `sync_all`, and `publish` is `persist` plus the
directory sync.

### What `Data.write(options: .atomic)` does

Foundation's `Data.write` comes from the open-source
[swift-foundation](https://github.com/swiftlang/swift-foundation), which Apple's
Foundation is built on. Reading `Sources/FoundationEssentials/Data/Data+Writing.swift`
(at commit `88028b7`), `.atomic`:

- writes a temporary file and calls plain `fsync` (not `F_FULLFSYNC`), then
  `renameat`s it over the target, and doesn't flush the directory;
- **keeps the target's permissions**: it reads the existing file's mode before writing,
  and `fchmod`s the temporary file to match before the rename;
- gives up on atomicity on two errors: when `rename` fails with `EINVAL` ("rename() fails
  on DOS file systems if newname already exists"), it swaps names in two steps, and with
  `EBUSY` it "Tr[ies] again, non-atomically" by overwriting the target in place.

`FileManager.replaceItemAt` is the other candidate. It's built for document-style
safe saves (it can keep a backup item and preserve metadata), but it documents no
flushing guarantee either. And neither API can split "write" from "rename", which is
the property §4 depends on.

So `LocalFileSystem` does it by hand:

```swift
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
```

```swift
    private static func flushToDrive(_ descriptor: Int32) throws(FileSystemError.Cause) {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard [ENOTSUP, ENOTTY, EINVAL].contains(errno) else { throw errnoCause() }
        guard fsync(descriptor) == 0 else { throw errnoCause() }
    }
```

Notes on the details:

- **Permissions** follow Foundation: the new `book.json` gets the old one's mode. The
  new `bak1` gets `book.json`'s mode too, not the old `bak1`'s, so a private (0600)
  book keeps private backups, and an unreadable old `bak1` doesn't make the new one
  unreadable. (The tests caught that last case.) Extended attributes are not copied.
- **The `fsync` fallback** only applies when the file system says `F_FULLFSYNC` isn't
  supported (`ENOTSUP`, `ENOTTY` or `EINVAL`, as on SMB and some FUSE volumes). Any
  other error is a real failure.
- **`publish`** renames and then flushes the directory the same way, which makes the
  rename itself durable (`F_FULLFSYNC` on a directory descriptor returns 0 on APFS;
  checked). A failure to flush the directory is logged, not thrown: the new file is
  already in place, so reporting "the save failed" would be false. `createDirectory`
  flushes the parent directory for the same reason.
- **The temporary name** is unique (a UUID), so two processes saving at once can't
  write into the same file. A crash can leave a hidden `.book.json.<uuid>.tmp` behind.
  It's harmless, because nothing reads it; cleaning these up is issue #49.
- **The stamp** of the new file is taken with `fstat` before the rename. A rename
  changes neither the modification time nor the inode, so that's the stamp
  `book.json` has afterwards, recorded without a step that could fail after the file
  was already replaced.

### Other volumes

Books can live on USB sticks. On FAT32, exFAT and HFS+ disk images on this machine,
repeated saves, the unchanged check and a crash at every step (§6) all behaved as on
APFS, and the stamp read back after `publish` matched the `fstat` stamp in 10 of 10
saves on each. Renaming over an existing file worked on FAT32 too, so the `EINVAL`
case that swift-foundation guards against didn't occur here. The differences to
know about: FAT and exFAT have no POSIX permissions, so copying the mode may fail
(that's logged, not fatal), and `man 2 fcntl` lists `F_FULLFSYNC` for FAT but not
exFAT, where the `fsync` fallback applies if the call is refused.

## 6. What a crash or a failure leaves behind

Start from a package where `book.json` is version V0 and the backups are V1–V3,
and save V9. Each row is the state on disk if the process dies right after that step.
Every step is either in memory, a read, a durable write under a hidden name, or a
`rename`, so there are no torn states between rows, at worst a stray temporary file.

| Crash after | `book.json` | `bak1` | `bak2` | `bak3` | Opens as |
| --- | --- | --- | --- | --- | --- |
| encode, verify, the checks, the reads | V0 | V1 | V2 | V3 | V0 |
| writing the temporary `bak1` and `book.json` | V0 | V1 | V2 | V3 | V0, plus stray temporary files |
| `bak2` → `bak3` | V0 | V1 | — | V2 | V0 |
| `bak1` → `bak2` | V0 | — | V1 | V2 | V0 |
| publishing `bak1` | V0 | V0 | V1 | V2 | V0 |
| publishing `book.json` | V9 | V0 | V1 | V2 | V9 |

- **`book.json` is always present and whole**, and it's V0 or V9.
- **Nothing but V3 is ever lost**, and V3 is the version this save retires anyway.
- **The next save repairs the gaps.** In every row, saving V9 again ends with
  `bak1`–`bak3` = V0, V1, V2.

Errors (as opposed to crashes) depend on the step that fails:

| Failing step | Result | Backups lost |
| --- | --- | --- |
| encode, verify, inspecting or reading `book.json` | throws; nothing changed | none |
| writing either temporary file (full disk, I/O error) | throws; nothing changed | none |
| inspecting or reading `bak1` | treated as "different"; saves normally | V3 (normal rotation) |
| `bak2` → `bak3` | `.saved(.degraded)`: `bak1` V0, `bak2` V1, `bak3` V3 | V2 instead of V3 |
| `bak1` → `bak2` | `.saved(.degraded)`: `bak1` V0, `bak2` —, `bak3` V2 | V1 and V3 |
| publishing `bak1` | `.saved(.degraded)`: `bak1` —, `bak2` V1, `bak3` V2 | V3, and V0 has no backup |
| publishing `book.json` | throws; `book.json` is V0, backups V0, V1, V2 | V3; retries lose nothing more |

So only a failed *rename* can cost more than the retiring V3, and a rename fails only
when a slot is damaged or the volume misbehaves. In that case the save still succeeds
and says so.

## 7. Noticing someone else's changes

Dropbox, `git checkout` or a text editor can replace `book.json` while the app has
it open. Saving over that would silently throw their version away. So `BookPackage`
remembers the `FileStamp` (size, nanosecond modification time and inode) and a SHA-256
digest of the `book.json` it last read or wrote, and a save compares:

```swift
            if stamp != lastSeen.stamp {
                if ContentDigest(current) == lastSeen.digest {
                    lastSeen.stamp = stamp
                } else if policy == .refuse {
                    throw refusal(.changed)
                }
            }
```

- A **touched** file, or one **copied back with identical bytes**, has a new stamp but
  our digest, so the new stamp is adopted silently.
- A **changed** file throws `SaveError.externallyModified(.changed)`, and a removed one
  throws `.removed`, unless the caller passes
  `onExternalChange: .overwriteKeepingTheirsAsBackup`. With that policy, the other
  program's version is rotated into `bak1` like any other current version, so nothing
  is lost, and a removed `book.json` is recreated.
- Anything that **isn't a file** (a directory or a link where `book.json` was) is
  `.notAFile` and is refused under either policy.

What to offer the writer is the store's decision (#11). When opening, the stamp is
taken *before* reading, so a change that lands mid-read makes the next save look again
rather than overwrite it.

This doesn't close the race where another program writes between the check and our
rename. Closing it needs a lock, which ADR 0005 leaves for later.

## 8. Permissions and locks

A save would succeed on a read-only (0444) or locked (Finder's "Locked") `book.json`,
because a rename only needs permission on the *directory*. That would silently undo the
writer's protection, so the save refuses with `SaveError.writeProtected(.readOnly)` or
`(.locked)` before writing anything.

## 9. Loading: all or nothing, and never a write

```swift
    /// Reads, decodes and validates `book.json`, all or nothing. Never writes.
    public static func open(
        at url: URL, fileSystem: any FileSystem = LocalFileSystem()
    ) throws(LoadError) -> OpenedBook {
```

`open` checks the extension, that the package is a directory and that `book.json` is a
regular file. It doesn't follow links: a symbolic link at `book.json` is
`.bookNotAFile`, and so is a named pipe, which would block a read forever. Then it
reads, decodes and validates. It builds the `Book` only when all of that succeeds, so
there's no partially loaded state to clean up. Failures become a `LoadError`: the
problem, plus the backups that exist with their modification times, so the message
tells the writer what they could restore by hand:

```
Couldn't open Novel.sceneit: book.json isn't a valid book:
- scene "01JC4K00000000000000000001" (scenes[0]), body[0][1]: a run's text is empty
Backups in the package:
- book.json.bak1 (last modified 2026-11-01T17:03:12Z)
- book.json.bak2 (last modified 2026-11-01T17:03:12Z)
- book.json.bak3 (last modified 2026-11-01T17:03:12Z)
```

Nothing is restored automatically: guessing which backup the writer wants is
exactly the kind of guess the trust rules forbid.

## 10. The testing seam: a Swift protocol where Rust would use a trait

```swift
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
```

These are exactly the operations create, open and save use. `publish` only accepts a
`TemporaryFile`, so nothing can "publish" a file that wasn't written durably first.

In Rust you'd write `trait FileSystem` and either make `BookPackage<F: FileSystem>`
generic (static dispatch) or store a `Box<dyn FileSystem>`. `BookPackage` stores
`any FileSystem`, the existential that matches `Box<dyn …>`: a dynamically
dispatched box. A generic parameter would leak into every type that holds a
package, the store included, for a few calls per save that cost far less than one
`F_FULLFSYNC`. `Sendable` on the protocol is the `+ Send + Sync` bound: it's what
lets a `BookPackage` cross to whichever executor the store saves on.

The test double, `FaultInjectingFileSystem`, wraps the real `LocalFileSystem` (so
tests run against real temporary directories), records every call, and either fails
a chosen call or simulates the process dying there (that call and every later one do
nothing, and a temporary file being written is left half-written). Its state is behind
a `Mutex` from the `Synchronization` module, the equivalent of `std::sync::Mutex`,
which is what lets a `final class` be `Sendable` without `@unchecked`. `BookPackage`
uses the same pattern.

The tests that use it:

- **Every step.** `SaveFault` lists the steps of a save in order, each mapped to the
  call it makes, together with the row of §6's error table it must produce. One test
  checks that a clean save makes *exactly* those calls in that order, so the list
  can't miss a step. One parameterized test fails each step (twice in a row for the
  steps that throw) and checks the files against the row, that no temporary file is
  left behind, and that a clean retry ends in the standard layout.
- **Crashes.** The same steps with a simulated crash: a fresh `open` on the real file
  system must load V0, and the next save must converge. A crash after the last step
  must load V9.
- **Damaged backups.** An unreadable `bak1`, a directory at `bak3` and a locked `bak1`
  never stop `book.json` from being saved.
- **External changes and protection.** Rewritten, removed, touched, replaced with
  identical bytes, and replaced by a directory, under both policies; a read-only and a
  locked `book.json`; permissions kept across a save.
- **Loading damaged packages.** Truncated, empty, garbage, an invalid book, an
  unsupported format, a missing `book.json`, a directory, a link or a dangling link
  where `book.json` should be, an unreadable `book.json`, a file where the package
  should be, a missing package and a missing extension. Each must throw the right
  `LoadProblem`, make no mutating call, and leave the directory listing, contents and
  modification times unchanged.
- **Fuzzing.** 400 seeded random edits of a valid file (byte changes, insertions,
  deletions, truncations): each either loads a book that passes the validator or
  throws a `LoadError`, and never writes. The test asserts that both outcomes
  occurred, so it can't silently degenerate into testing only one.
- **Rotation.** Five saves of distinct content leave `bak1`–`bak3` byte-equal to the
  previous three versions, and an unchanged save leaves the whole package untouched.
