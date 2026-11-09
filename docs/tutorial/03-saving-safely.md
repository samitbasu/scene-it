# 03 — Saving safely

How a book gets onto disk without ever being lost or half-loaded, explained for someone
who has written `tempfile` + `persist` in Rust.

The rules come from [WORKFLOW.md](../dev/WORKFLOW.md)'s trust section: never write
`book.md` without serialize → verify → rotate → atomic write; a failed load never
half-loads or overwrites anything; refuse with a clear error rather than guess. Two
decision records refine them: [ADR 0018](../decisions/0018-external-change-ux.md) (what
happens when another program changed the book) and
[ADR 0019](../decisions/0019-backup-failure-policy.md) (what happens when a backup can't
be written). This chapter shows how each rule turns into code, and what each step does and
doesn't guarantee if the power goes out.

## Where the code is

Everything lives in [`Sources/SceneItCore/Persistence/`](../../Sources/SceneItCore/Persistence/):

| File | What it holds |
| --- | --- |
| [`BookPackage.swift`](../../Sources/SceneItCore/Persistence/BookPackage.swift) | create, open and save; the save pipeline |
| [`PackageLayout.swift`](../../Sources/SceneItCore/Persistence/PackageLayout.swift) | where each file lives in a `.sceneit` package; `BackupSlot` |
| [`FileSystem.swift`](../../Sources/SceneItCore/Persistence/FileSystem.swift) | the file-system protocol (the testing seam), `FileItem`, `FileSystemError` |
| [`LocalFileSystem.swift`](../../Sources/SceneItCore/Persistence/LocalFileSystem.swift) | the real implementation: POSIX calls, `F_FULLFSYNC`, `renamex_np` |
| [`PersistenceErrors.swift`](../../Sources/SceneItCore/Persistence/PersistenceErrors.swift) | `SaveError`, `SaveOutcome`, `BackupStatus`, `ExternalChangePolicy`, `CreateError`, `LoadError` |
| [`SnapshotSchedule.swift`](../../Sources/SceneItCore/Persistence/SnapshotSchedule.swift) | the pure snapshot cadence and retention tiers; `SnapshotName` |
| [`BackupKeeper.swift`](../../Sources/SceneItCore/Persistence/BackupKeeper.swift) | tiered snapshots in the package and the external mirror; `BackupMirror`, `SnapshotReport` |
| [`StrayTemporaryFiles.swift`](../../Sources/SceneItCore/Persistence/StrayTemporaryFiles.swift) | clearing away the temporary files a crashed save or snapshot leaves |
| [`Archive.swift`](../../Sources/SceneItCore/Persistence/Archive.swift), [`ArchiveReconciliation.swift`](../../Sources/SceneItCore/Persistence/ArchiveReconciliation.swift) | File a Copy and launch reconciliation (section 14) |
| [`UTCStamp.swift`](../../Sources/SceneItCore/Persistence/UTCStamp.swift) | the `20261101T143005Z` stamp in snapshot and conflict file names |
| [`ExclusiveFileLock.swift`](../../Sources/SceneItCore/Persistence/ExclusiveFileLock.swift) | the `flock` wrapper, `LockAttempt` |
| [`LockRecord.swift`](../../Sources/SceneItCore/Persistence/LockRecord.swift) | the advisory record, `LockRecordPolicy`, `ThisMac` |
| [`ReadOnlyWording.swift`](../../Sources/SceneItCore/Persistence/ReadOnlyWording.swift) | what the writer is told when a book opens read-only |
| [`Launch/LaunchGate.swift`](../../Sources/SceneItCore/Launch/LaunchGate.swift) | the app-wide lock at launch, `ProcessRole` |

The tests are in [`Tests/SceneItCoreTests/Persistence/`](../../Tests/SceneItCoreTests/Persistence/).

---

## 1. The package

A book is a directory named `My Novel.sceneit` that Finder shows as one document
([ADR 0004](../decisions/0004-book-is-a-package.md)):

```
My Novel.sceneit/
  book.md                   the book, format 2 (ADR 0022)
  book.md.bak1 … bak3       the last three versions, newest first
  book.md.original-<time>.md  a damaged book's original, kept by Make Editable (ADR 0024, §13)
  Archive/index.md          just "format: 2" front matter in a new book (PLAN §5.5, format §8)
  Archive/save0001.md …     filed copies, exact copies of book.md (the archive, #32)
  Backups/                  tiered snapshots and book-id (ADR 0005, §11)
  .lock                     locked while the book is open for editing (ADR 0020, §12)
```

Every copy of the book is a `.md` file named after `book.md`. There's no migration from
the JSON `book.json` of builds before format 2 (ADR 0022): a package holding only that
fails to open with `LoadProblem.legacyJSONBook`, rather than opening as an empty book that
the writer might type into. `PackageLayout.legacyBookFileName` is the one place in the
sources that still names it, and a test checks that.

`PackageLayout` is the one place that knows those names. Everything else asks it,
for example `layout.backup(.bak2)`. A new book is created empty, with no scenes,
which PLAN §4.2 allows (the rail's "current scene" is grayed out). `book.md` is
the last thing `create` writes, so a creation interrupted halfway leaves a package
that `open` refuses with "the package has no book.md" instead of something that
looks like a book.

`BookPackage` is a `final class`, not a struct. It remembers a digest of the
`book.md` it last read or wrote (§7), and two copies of a struct could each remember
something different and then disagree about whether the file had changed. Its state is
behind a `Mutex`, so two saves can't interleave either.

## 2. `throws` and typed errors

Chapter 00 §6 introduced typed throws. Persistence is where they pay off: the store
(#11) has to show a different message for "your book is invalid", "the disk is full",
"the file is locked", "another program changed the file" and "backups aren't working",
and an exhaustive `switch` over a typed error makes the compiler check that it handles
them all. Each entry point names its error type:

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

A save that succeeds can still have something to say, so `SaveOutcome` is `.unchanged`
or `.saved(BackupStatus, PublishedBook)` (the bytes it wrote, §11). `BackupStatus` is `.intact`, or
`.previousVersionNotBackedUp(error, olderBackups:)` when the rotation failed (§4), where
`olderBackups` says whether the oldest backup had already been retired.

File-system errors are typed down to the cause. `FileSystemError.Cause` names the
ones the store can explain (`.noSpace`, `.permissionDenied`, `.readOnlyVolume`,
`.unsupported`, `.io`, …) and keeps the rest as `.other(POSIXErrorCode)` rather than as
a string.

There's no `From`, so every boundary converts by hand. When the calls in a `do`
block throw one type, the `catch` infers it. A `throw` statement of another type inside
the block makes the inferred type fall back to `any Error`, and the fix is to state it:
`do throws(SaveError) {`, as `replaceBook` (§4) does. Where a single call has to be
wrapped inline, a small generic helper does it. Its closure needs the explicit
`() throws(FileSystemError) in`, because (chapter 00 §6) closures don't infer typed
throws:

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
    public func save(
        _ book: Book, onExternalChange policy: ExternalChangePolicy = .refuse
    ) throws(SaveError) -> SaveOutcome {
        let data: Data
        do {
            data = try BookFormat.verifiedSerialization(of: book)
        } catch {
            Log.store.fault("the serialized book failed verification", ["error": .error(LoggedError(error))])
            throw .encoding(error)
        }
        return try lastSeen.withLock { (lastSeen) throws(SaveError) -> SaveOutcome in
            let current = try readCurrent(lastSeen, policy)
            if current?.data == data {
                Log.store.debug("book unchanged; nothing saved")
                return .unchanged
            }
            let backups = try replaceBook(with: data, current: current, &lastSeen)
            lastSeen = ContentDigest(data)
            Log.store.info("saved the book", ["bytes": .bytes(Int64(data.count))])
            return .saved(backups, PublishedBook(data: data))
        }
    }
```

In order:

1. **Serialize and verify.** `save(_ book:)` calls `BookFormat.verifiedSerialization`
   (chapter 02 §6): serialize, parse the bytes, and require that serializing the result
   gives the *same bytes* and that the parse found no error entries the book didn't
   already have:

   ```swift
           guard serialize(reread) == bytes else { throw .unstable }
   ```

   Not `Book ==`: Swift's `String ==` compares canonical equivalence, so `"é"`
   written as one code point (NFC) equals `"e"` plus a combining accent (NFD). Two
   "equal" books can serialize differently, and comparing values would hide exactly
   the kind of drift this step exists to catch. A failure is `SaveError.encoding`, and
   nothing is written.
2. **Read `book.md`, and decide whose it is.** Refuse a read-only or locked file (§8).
   Compare the bytes' digest with the one remembered: equal means *ours*, otherwise
   *theirs*, which `.refuse` turns into an error (§7).
3. **Skip unchanged.** If `book.md` already holds these exact bytes, return
   `.unchanged` without touching anything. Autosave runs every couple of seconds;
   if it rotated each time, three idle autosaves would push every real backup out.
4. **Replace,** in two phases: write everything, then rename (§4).

Every failure is logged through `Log.store` (chapter 11) before it's thrown. The
log gets the operation and cause as fixed symbols (`operation=write cause=noSpace`),
never the path: a path contains the book's title, and the `Log` API only accepts
`StaticString` messages and `LogValue` metadata, so it couldn't carry one anyway.

## 4. Write everything, then rename

PLAN §5.4 says "rotate `bak2`→`bak3`, `bak1`→`bak2`, `book.md`→`bak1`, then write".
Done in that order, the rotation has already happened when the write fails, so a full
disk costs a backup every time. And done literally with renames, there's a moment
with no `book.md` at all.

So the save splits into two phases. **Phase 1 writes**: a durable temporary copy of
the current `book.md` (the new `bak1`) and a durable temporary copy of the new book.
Those writes are the only steps that can fail because the disk is full or a sector
is bad, and when they fail nothing visible has changed yet. **Phase 2 only renames.**
`book.md` is never moved, just replaced in one step by its new version.

```swift
    private func replaceBook(
        with data: Data, current: Current?, _ lastSeen: inout ContentDigest
    ) throws(SaveError) -> BackupStatus {
        var unpublished: [URL] = []
        do throws(SaveError) {
            var backup: (file: TemporaryFile, bak1: Bak1)?
            if let current {
                let bak1 = bak1Holding(current.data)
                if bak1 != .holdsCurrent {
                    let file = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
                        try fileSystem.writeTemporary(
                            current.data, for: layout.backup(.bak1), permissionsFrom: layout.book)
                    }
                    unpublished.append(file.url)
                    backup = (file, bak1)
                }
            }
            let replacement = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
                try fileSystem.writeTemporary(data, for: layout.book, permissionsFrom: layout.book)
            }
            unpublished.append(replacement.url)
            var status = BackupStatus.intact
            if let backup, let current {
                do {
                    try rotateBackups(publishing: backup.file, over: backup.bak1)
                } catch {
                    guard current.owner == .ours else { throw .couldNotBackUpTheirVersion(error.cause) }
                    Log.store.error(
                        "couldn't back up the previous version; saving anyway", error.cause.logMetadata)
                    fileSystem.discard(backup.file.url)
                    status = .previousVersionNotBackedUp(error.cause, olderBackups: error.olderBackups)
                }
            }
            unpublished = []
            try replace(with: replacement, holding: data, expecting: current?.data, &lastSeen)
            return status
        } catch {
            unpublished.forEach(fileSystem.discard)
            Log.store.error("couldn't save the book")
            throw error
        }
    }
```

The rotation stops at its first failure:

```swift
    private func rotateBackups(publishing backup: TemporaryFile, over bak1: Bak1) throws(RotationFailure) {
        var olderBackups = OlderBackups.untouched
        let shifts: [(BackupSlot, BackupSlot)] = bak1 == .absent ? [] : [(.bak2, .bak3), (.bak1, .bak2)]
        for (source, destination) in shifts {
            do {
                try fileSystem.move(layout.backup(source), over: layout.backup(destination))
            } catch  where error.cause == .notFound {
                continue
            } catch {
                throw RotationFailure(cause: error, olderBackups: olderBackups)
            }
            if destination == .bak3 { olderBackups = .oldestRetired }
        }
        do {
            try fileSystem.publish(backup, as: layout.backup(.bak1))
        } catch {
            throw RotationFailure(cause: error, olderBackups: olderBackups)
        }
    }
```

### The backup policy (ADR 0019)

One rule covers the rotation: **a save destroys nothing but the version in `bak3`**. Every
shift moves into a slot the previous shift emptied, `publish` refuses to replace anything
(§5), and the first failure stops the rotation before it can overwrite a distinct version.
What happens next depends on whose version `book.md` holds:

| `book.md` holds | The rotation fails | Result |
| --- | --- | --- |
| our own last save | at any step | **Save anyway**: `.saved(.previousVersionNotBackedUp(error, olderBackups:), _)`. The new book contains the old one plus the edits; refusing would leave the session's typing only in memory. The store shows "Backups aren't working". |
| another program's version (`.overwriteKeepingTheirsAsBackup(theirs:)`) | at any step | **Refuse**: `SaveError.couldNotBackUpTheirVersion`. Nothing is published, and their version stays in `book.md`. |

Other details:

- **A missing slot absorbs the shift.** A missing `bak2` is `.notFound` and is skipped,
  so `bak3` keeps its version. A missing `bak1` means nothing shifts at all. A retry
  after a crash fills the gap instead of discarding another version.
- **`bak1 == book.md` means "already backed up".** If the final rename failed, `bak1`
  already holds the current version. Without this check, every failing autosave would
  shift again, and three of them would replace all the backups with copies of the
  current book. `bak1Holding` compares sizes before reading, and anything it can't read
  counts as different, so an unreadable `bak1` costs a rotation, never a save.
- **Damaged slots.** A locked `bak1`, or a directory at `bak2` or `bak3`, makes a rename
  fail. The rotation stops and leaves the versions where they are, and our own save goes
  ahead with `.previousVersionNotBackedUp`.

A backup's modification time is *when that version was superseded*: the copy into
`bak1` is a new file, and renames keep it. `LoadError` lists those times.

## 5. Atomic, durable writes on APFS

### What `rename(2)` gives you

POSIX `rename` replaces the destination name in one step: any process looking at
`book.md` sees the old file or the new one, never a mix or nothing. APFS keeps that
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
`F_FULLFSYNC`. A save flushes two files, and the directory after each rename (up to
five), which is a fine price for a novel.

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
`writeTemporary` is everything up to `sync_all`, and the renames (`publish`, `exchange`,
`move`) are `persist` plus the directory sync.

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
            path: TemporaryFile.name(for: destination.lastPathComponent, id: UUID()),
            directoryHint: .notDirectory)
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
```

```swift
    private static func flushToDrive(_ descriptor: Int32) throws(FileSystemError.Cause) {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard [ENOTSUP, ENOTTY, EINVAL].contains(errno) else { throw errnoCause() }
        guard fsync(descriptor) == 0 else { throw errnoCause() }
    }
```

### Three kinds of rename

`rename(2)` silently replaces whatever is at the destination. The seam offers three
renames so that each call states what it may replace:

- **`publish`** may replace *nothing*: `renamex_np(…, RENAME_EXCL)` fails with `EEXIST`
  if the destination exists. It's used for a new `bak1` and for a new package's files,
  so a rotation can never overwrite a version by mistake.
- **`exchange`** swaps two names in one step (`RENAME_SWAP`). It's used for `book.md`
  (§7).
- **`move`** is plain `rename`, used only to shift backups down.

Both flags depend on the volume, and the volume's *declared* capability is what counts:

```swift
    /// Only on volumes that declare swap support: FAT32 on macOS 27 returns success from
    /// `RENAME_SWAP` but performs a plain rename, destroying the destination.
    public func exchange(_ temporary: TemporaryFile, with destination: URL) throws(FileSystemError) {
        guard Self.volume(of: destination, declares: .swapRename) else {
            throw FileSystemError(.exchange, destination, .unsupported)
        }
```

That comment records something found while testing. On FAT32 disk images,
`renamex_np(a, b, RENAME_SWAP)` returned 0, `a` was gone, and `b` held `a`'s contents:
the "swap" had quietly overwritten `b`. exFAT and HFS+ correctly return `ENOTSUP`. All
three declare `volumeSupportsSwapRenaming == false`, so asking the volume first avoids the
bug. FAT32 and exFAT also don't declare `RENAME_EXCL`; there, `publish` checks that the
destination is absent and then renames, which leaves a window of microseconds.

### Other details

- **Permissions** follow Foundation: the new `book.md` gets the old one's permission
  bits. The new `bak1` gets `book.md`'s bits too, not the old `bak1`'s, so a private
  (0600) book keeps private backups, and an unreadable old `bak1` doesn't make the new one
  unreadable. Older backups keep the bits they had, so a change to `book.md`'s
  permissions reaches all three backups over three saves. Only the 0o777 bits are copied:
  setuid, setgid and sticky are dropped. ACLs and extended attributes are not carried
  over.
- **The `fsync` fallback** only applies when the file system says `F_FULLFSYNC` isn't
  supported (`ENOTSUP`, `ENOTTY` or `EINVAL`, as on SMB and some FUSE volumes). Any
  other error is a real failure.
- **Every rename flushes the directory** (`F_FULLFSYNC` on a directory descriptor returns
  0 on APFS; checked), which makes it durable. A failure to flush the directory is logged,
  not thrown: the change is already in place, so reporting failure would be false.
  `createDirectory` flushes the parent directory for the same reason.
- **The temporary name** is unique (a UUID), so two processes saving at once can't
  write into the same file. A crash can leave a hidden `.book.md.<uuid>.tmp` behind.
  Nothing reads it; a later save clears it away (§6).

### Other volumes

Books can live on USB sticks. On FAT32, exFAT and HFS+ disk images on this machine,
repeated saves, the unchanged check, a crash at every step (§6) and a concurrent write
during a save (§7) all behaved as on APFS once the swap was gated as above. On a tiny APFS
volume filled until a save hit a real `ENOSPC`, every attempt was refused with
`.noSpace` and left the package byte-identical, with no temporary files. FAT and exFAT
have no POSIX permissions, so copying the mode may fail (that's logged, not fatal), and
`man 2 fcntl` lists `F_FULLFSYNC` for FAT but not exFAT, where the `fsync` fallback
applies if the call is refused.

## 6. What a crash or a failure leaves behind

Start from a package where `book.md` is version V0 (our own last save) and the
backups are V1–V3, and save V9. Each row is the state on disk if the process dies right
after that step. Every step is either in memory, a read, a durable write under a hidden
name, or a rename, so there are no torn states between rows, at worst a stray temporary
file.

| Crash after | `book.md` | `bak1` | `bak2` | `bak3` | Opens as |
| --- | --- | --- | --- | --- | --- |
| encode, verify, the checks, the reads | V0 | V1 | V2 | V3 | V0 |
| writing the temporary `bak1` and `book.md` | V0 | V1 | V2 | V3 | V0, plus stray temporary files |
| `bak2` → `bak3` | V0 | V1 | — | V2 | V0 |
| `bak1` → `bak2` | V0 | — | V1 | V2 | V0 |
| publishing `bak1` | V0 | V0 | V1 | V2 | V0 |
| exchanging `book.md` | V9 | V0 | V1 | V2 | V9 (V0 also at a stray temporary name) |

- **`book.md` is always present and whole**, and it's V0 or V9.
- **Nothing but V3 is ever lost**, and V3 is the version this save retires anyway.
- **The next save repairs the gaps.** In every row, saving V9 again ends with
  `bak1`–`bak3` = V0, V1, V2.

Errors (as opposed to crashes), when `book.md` holds our own last save:

| Failing step | Result | `book.md`, `bak1`–`bak3` afterwards |
| --- | --- | --- |
| encode, verify, inspecting or reading `book.md` | throws; nothing changed | V0; V1, V2, V3 |
| writing either temporary file (full disk, I/O) | throws; nothing changed | V0; V1, V2, V3 |
| inspecting or reading `bak1` | treated as "different"; saves normally | V9; V0, V1, V2 |
| `bak2` → `bak3` | `.saved(.previousVersionNotBackedUp(_, .untouched), _)` | V9; V1, V2, V3 |
| `bak1` → `bak2` | `.saved(.previousVersionNotBackedUp(_, .oldestRetired), _)` | V9; V1, —, V2 |
| publishing `bak1` | `.saved(.previousVersionNotBackedUp(_, .oldestRetired), _)` | V9; —, V1, V2 |
| exchanging `book.md` | throws; retries don't rotate again | V0; V0, V1, V2 |
| reading the displaced file after the exchange | swapped back; `.externallyModified(.changed(theirs:))` | V0; V0, V1, V2 |

When `book.md` holds another program's version (saving with
`.overwriteKeepingTheirsAsBackup(theirs:)`), the three rotation rows throw
`.couldNotBackUpTheirVersion` instead, and `book.md` keeps their version.

### Clearing away stray temporary files

A crash in the second row leaves hidden `.book.md.<UUID>.tmp` and
`.book.md.bak1.<UUID>.tmp` files behind. Every save that writes then calls
`StrayTemporaryFiles.sweep(now:)`
([`StrayTemporaryFiles.swift`](../../Sources/SceneItCore/Persistence/StrayTemporaryFiles.swift)),
after `book.md` is published and while the book's lock is held (§12), so no other copy of
Scene It is writing into the package. `open` never sweeps (loading never writes), and a
read-only book has no `BookPackage`, so it can't. An `.unchanged` save doesn't sweep either.

The rules, each one there to keep a version from being lost:

- **The name must match exactly.** `TemporaryFile.name(for:id:)` is the one place the
  temporary name is made, and `TemporaryFile.destination(ofName:)` parses it back with
  `^\.(.+)\.[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.tmp$` (upper-case
  UUID, matched scalar by scalar); the destination must be `book.md` or `book.md.bak1`,
  the only two a save writes. Only regular files count: a link or a folder with that name is
  left alone.
- **It must be at least 10 minutes old** (`minimumAge`, an `Interval`), so a write still in
  progress elsewhere isn't touched.
- **It's removed only if its bytes are already kept**: the same size and bytes as
  `book.md`, `bak1`–`bak3` or a snapshot in `Backups/`. A crash during a save leaves
  either the new book (now in `book.md`) or the old one (in a backup), so this is the
  normal case. The size comes first: a stray whose size no kept file has isn't even read,
  and each kept file is read (and hashed) at most once per sweep.
- **Anything else is renamed, never removed**, to `book.md.recovered-<UTC time>.md`
  (the file's modification time; `-2`, `-3`, … on a clash, never replacing anything). This is
  §7's double fault: another program's version left at the temporary name when it couldn't
  be swapped back or renamed. `keepAsConflict` and this rename share one helper,
  `FileSystem.publishUnderFreeName`.
- **What's removed is the file that was compared, not whatever has its name.** The stray is
  opened once with `FileSystem.open` (`O_NOFOLLOW`, and `O_NONBLOCK` so a pipe swapped in
  can't hang the save while it holds the package's mutex), `fstat`ed and read through that
  descriptor. To remove it, it's first renamed (never replacing anything) to a fresh
  temporary name, and removed only if the file there has the same inode, size and
  modification time; anything else found there is recovered instead. A program that writes
  the old name afterwards writes a new file, which the sweep doesn't touch.

Nothing in the sweep throws. Each failure is logged (metadata only) and leaves the file
where it is, and the save's outcome is the same as without it.

`BackupKeeper` (§11) writes snapshots, `book-id` and the mirror's `package.json` the same
way, so a crash there leaves `.book-<time>.md.<UUID>.tmp`, `.book-id.<UUID>.tmp` or
`.package.json.<UUID>.tmp` in `Backups/` or the book's mirror folder. The same
`StrayTemporaryFiles` sweeps those folders too: one implementation, given the folder and what
each destination's temporary file holds (its private `Contents` enum). Its two initializers
are the whole difference:

| Folder | Destinations | A copy of `book.md` is kept if it matches | Metadata |
| --- | --- | --- | --- |
| package root, `init(packageRoot:fileSystem:)` | `book.md`, `book.md.bak1` | `book.md`, `bak1`–`bak3`, a snapshot in `Backups/` | — |
| `Backups/`, `init(snapshotsIn:metadata:…)` | any snapshot name, `book-id` | a snapshot in `Backups/`, `book.md`, `bak1`–`bak3` | `book-id` |
| mirror folder, `init(snapshotsIn:metadata:…)` | any snapshot name, `package.json` | a snapshot in that folder | `package.json` |

The mirror counts only its own snapshots, because it has to outlive the package. A copy of
`book.md` kept nowhere is recovered as `book.md.recovered-<time>.md` *in the folder it
was found in*, a name `SnapshotName` doesn't parse, so pruning never removes it.

Metadata is treated differently. A temporary `book-id` or `package.json` was never published,
so nothing refers to it: a mirror folder is only ever named by a published `book-id`, and a
temporary `package.json` claimed nothing. It's removed, whatever it holds, as long as the
file it would have replaced is a regular file that parses: a UUID, or a package record with
an absolute path. Otherwise it's left alone. `BackupKeeper` replaces a corrupt `book-id`
itself, and the next sweep removes the stray. Recovering it would only leave a meaningless
UUID beside the user's books.

## 7. Noticing someone else's changes

Dropbox, `git checkout` or a text editor can replace `book.md` while the app has
it open. Saving over that would silently throw their version away. So `BookPackage`
remembers a SHA-256 digest of the `book.md` it last read or wrote, and a save compares
the digest of what's there now. The bytes are read anyway (for the unchanged check and
the backup), so there's no cheaper signal worth trusting more: size and modification time
can be restored by a careful writer, and one of the tests does exactly that.

```swift
            let digest = ContentDigest(data)
            if digest == lastSeen { return Current(data: data, owner: .ours) }
            guard policy == .overwriteKeepingTheirsAsBackup(theirs: digest) else {
                throw refusal(.changed(theirs: digest))
            }
            return Current(data: data, owner: .theirs)
```

- A **touched** file, or one **copied back with identical bytes**, is still ours.
- A **changed** file throws `SaveError.externallyModified(.changed(theirs: digest))`, naming the
  version it found. The only way past it is `onExternalChange:
  .overwriteKeepingTheirsAsBackup(theirs: digest)` with *that* digest: the writer's "Keep My
  Version" approves exactly the version they were told about. The other program's version is
  rotated into `bak1` first (and the save is refused if that fails, §4). If a sync writes yet
  another version before the save, its digest differs, and the save throws `.changed` again
  with the new digest, so the writer is asked again (ADR 0018: each external change asks).
- A **removed** `book.md` throws `.removed`, unless the caller passes `.recreate`.
- Anything that **isn't a file** (a directory or a link where `book.md` was) is
  `.notAFile` and is refused under every policy.

The approval is a value carrying the digest, not a flag. A `Bool` named `keepMine` could
outlive the version it was about; a policy naming the version can't.

ADR 0018 decides what the writer sees.

### A write that lands during the save

The check above happens before the temporary files are written. Another program could
write `book.md` after it, and a plain rename would then replace their version without
anyone noticing. So the final step is a compare-and-swap:

```swift
    private func replace(
        with replacement: TemporaryFile, holding data: Data, expecting expected: Data?,
        _ lastSeen: inout ContentDigest
    ) throws(SaveError) {
        guard let expected else {
            do {
                return try fileSystem.publish(replacement, as: layout.book)
            } catch {
                fileSystem.discard(replacement.url)
                throw error.cause == .alreadyExists ? changedDuringSave() : .fileSystem(error)
            }
        }
        do {
            try fileSystem.exchange(replacement, with: layout.book)
        } catch  where error.cause == .unsupported {
            return try replaceWithoutExchange(replacement, expecting: expected)
        } catch {
            fileSystem.discard(replacement.url)
            throw .fileSystem(error)
        }
        if (try? fileSystem.read(replacement.url)) == expected {
            fileSystem.discard(replacement.url)
            return
        }
        do {
            try fileSystem.exchange(replacement, with: layout.book)
        } catch {
            throw keepAsConflict(replacement, published: data, &lastSeen)
        }
        fileSystem.discard(replacement.url)
        throw changedDuringSave()
    }
```

After the swap, the temporary name holds whatever `book.md` held *at the instant of the
swap*. If those aren't the bytes the save checked, another program renamed a new version
into place in between, and a second swap puts their version back. The save then throws
`.externallyModified(.changed(theirs:))` (`changedDuringSave` reads `book.md` again to name the
version that's there now),
which leads to ADR 0018's choice like any other external change. Swapping back, rather
than keeping their bytes under another name, leaves the package exactly as the other
program meant it, and needs nothing new from the store.

Two fallbacks remain, each documented in code:

- **The swap back fails** (a double fault). Their version is renamed to
  `book.md.conflict-<UTC time>` (with `-2`, `-3`, … if that name is taken), and the save
  throws `.externallyModified(.keptAsConflict(fileName:))`. If even that rename fails, the
  error names the hidden temporary file that holds it. The package then records the digest
  of the bytes *this save* wrote, never a fresh read of `book.md`: a third write landing
  at that moment would otherwise be taken for ours, and a later save could replace it
  without a backup. A regression test injects exactly that triple fault.
- **The volume can't swap** (FAT, exFAT, HFS+). The save re-reads `book.md` just
  before a plain rename. A write landing in the microseconds between the two is the one
  residual window.

Where the volume can swap, this closes the window for writers that **rename a new
version into place**, which is what sync services and most editors do. A writer that
already had `book.md` open and **edits it in place** can still write into the displaced
file after the comparison, and that write is lost when the file is discarded. That window
is small, and closing it would need a lock that other programs honour, which they don't.
Two copies of Scene It can't get here: the book lock of §12 lets only one of them edit.

## 8. Permissions and locks

A save would succeed on a read-only (0444) or locked `book.md`, because a rename only
needs permission on the *directory*. That would silently undo the writer's protection, so
the save refuses with `SaveError.writeProtected(.readOnly)` or `(.locked)` before writing
anything. `.locked` covers Finder's "Locked" (the immutable flag) and the append-only
flag, both of which make the final rename fail anyway. A writable file has no protection
value at all (`FileItem.file(_, protection: nil)`), so there's no "write-protected:
writable" state to handle.

## 9. Loading: all or nothing, and a failure never writes

```swift
    public static func open(
        at url: URL, onLockRecord policy: LockRecordPolicy = .respect, defaults: ParseDefaults = .system,
        fileSystem: any FileSystem = LocalFileSystem()
    ) throws(LoadError) -> OpenedBook {
```

The only thing a successful `open` writes is the book's `.lock` (§12), and it takes that
lock *after* the read, so a book that fails to load never gains one. Nor does a book whose
contents make it read-only (§13).

`defaults` is where the parse gets what a file leaves out: the time the book was opened (a
scene with no `modified`) and fresh scene ids. `.system` is the clock and ULIDs; the store
takes a `ParseDefaults` in its initializer and passes it down, so a test can make both
predictable (`ParseDefaults(opened: { fixedTime }, ids: { LetteredIDs() })`). Each parse
asks for a new id source, which is why it's a closure returning one rather than one shared
generator: the value crosses to the background task that does the I/O, so it must be
`Sendable`, and a mutable generator shared between parses wouldn't be.

`open` checks the extension, that the package is a directory and that `book.md` is a
regular file. It doesn't follow links: a symbolic link at `book.md` is
`.bookNotAFile`, and so is a named pipe, which would block a read forever. Then it
reads and parses. The parse never fails (chapter 02): damaged contents open, with what
couldn't be read kept as error entries. So only the file system can make `open` fail, and
there's no partially loaded state to clean up. Failures become a `LoadError`: the
problem, plus the backups that exist with their modification times, so the message
tells the writer what they could restore by hand:

```
Couldn't open Novel.sceneit: the package's book.md isn't a regular file (it may be a folder or a link)
Backups in the package:
- book.md.bak1 (last modified 2026-11-01T17:03:12Z)
- book.md.bak2 (last modified 2026-11-01T17:03:12Z)
- book.md.bak3 (last modified 2026-11-01T17:03:12Z)
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

    /// Removes the empty directory at `directory` (`rmdir`); never follows a link.
    func removeDirectory(_ directory: URL) throws(FileSystemError)

    /// Which file or directory is at `url`, whatever its path: `nil` if its volume has no
    /// UUID to tell it apart. Follows a symbolic link at `url`. Throws, rather than returning
    /// `nil`, when the volume's UUID can't be read, so a failure isn't taken for "no UUID".
    func identity(of url: URL) throws(FileSystemError) -> FileIdentity?
}
```

These are exactly the operations create, open and save use, plus the three that
snapshots need (§11), and `removeDirectory`, which the store (#11) uses to remove an
unfinished "(my edits)" copy. `publish` and `exchange`
only accept a `TemporaryFile`, so nothing can put a file in place that wasn't written
durably first.

In Rust you'd write `trait FileSystem` and either make `BookPackage<F: FileSystem>`
generic (static dispatch) or store a `Box<dyn FileSystem>`. `BookPackage` stores
`any FileSystem`, the existential that matches `Box<dyn …>`: a dynamically
dispatched box. A generic parameter would leak into every type that holds a
package, the store included, for a few calls per save that cost far less than one
`F_FULLFSYNC`. `Sendable` on the protocol is the `+ Send + Sync` bound: it's what
lets a `BookPackage` cross to whichever executor the store saves on.

The test double, `FaultInjectingFileSystem`, wraps the real `LocalFileSystem` (so
tests run against real temporary directories) and records every call. It can fail a
chosen call (with a chosen cause, optionally after letting the first few through),
simulate the process dying there (that call and every later one do nothing, and a
temporary file being written is left half-written), or run an action just before a
call, which is how the tests play "another program writes `book.md` mid-save". Its
state is behind a `Mutex` from the `Synchronization` module, the equivalent of
`std::sync::Mutex`, which is what lets a `final class` be `Sendable` without
`@unchecked`. `BookPackage` uses the same pattern.

The tests that use it:

- **Every step.** `SaveFault` lists the steps of a save in order, each mapped to the
  call it makes, together with its row of §6's error table. One test checks that a clean
  save makes *exactly* those calls in that order, so the list can't miss a step. One
  parameterized test fails each step (twice in a row for the steps that throw) and
  checks the files against the row, that no temporary file is left behind, and that a
  clean retry ends in the standard layout. Another fails each rotation step while
  `book.md` holds their version, and checks that nothing is published.
- **Crashes.** Each step with a simulated crash: the files must match §6's crash table, a
  fresh `open` on the real file system must load the right version, and the next save
  must converge.
- **Concurrent writes.** Another program's write lands between the check and the final
  rename, with and without swap support and under both policies: their version is never
  lost. A failed swap-back keeps it under a conflict name.
- **Damaged backups.** An unreadable `bak1`, a directory at `bak2` or `bak3`, and a locked
  `bak1`: the versions stay where they are, and our own save goes ahead and says so.
- **External changes and protection.** Rewritten, rewritten in place with the size and
  modification time restored, removed, touched, replaced with identical bytes, and
  replaced by a directory; a read-only, locked or append-only `book.md`; permissions
  kept across a save.
- **Loading damaged packages.** A missing `book.md`, a directory, a link or a dangling
  link where `book.md` should be, an unreadable `book.md`, a file where the package
  should be, a missing package and a missing extension. Each must throw the right
  `LoadProblem`, make no mutating call, and leave the directory listing, contents and
  modification times unchanged.
- **Damaged contents.** Truncated, empty, garbage and a newer format all open, and
  opening writes nothing but the lock.
- **Fuzzing.** 100 seeded random edits of a valid file (byte changes, insertions,
  deletions, truncations): each loads, and nothing but the lock is written. The format's
  own fuzz suite (chapter 02 §7) covers what the parse makes of them.
- **Rotation.** Five saves of distinct content leave `bak1`–`bak3` byte-equal to the
  previous three versions, and an unchanged save leaves the whole package untouched.
- **Mutation checks.** Removing the "theirs must be backed up" guard, the swap-back, or
  the stop-at-first-failure rule each makes these tests fail.

## 11. Tiered snapshots and the external mirror

`bak1…bak3` protect against a bad write, but with a 2-second autosave they can all be
seconds old. [ADR 0005](../decisions/0005-backups.md) adds history: after a save,
[`BackupKeeper`](../../Sources/SceneItCore/Persistence/BackupKeeper.swift) may copy
`book.md` to a snapshot in two places:

```
My Novel.sceneit/Backups/
  book-id                         this book's UUID
  book-20261101T143005Z.md      a snapshot: the UTC second it was taken
~/Library/Application Support/Scene It/Backups/<book-id>/
  package.json                    the package that writes here (see below)
  book-20261101T143005Z.md      the same snapshot
```

The mirror survives the package being deleted or mangled, for example by a sync service.
Snapshot names and `book.md.conflict-…` (§7) share one formatter, `UTCStamp`.

### Getting the exact bytes

A snapshot must hold exactly what was published, not a re-encoding. So a save that wrote
`book.md` says what it wrote: `SaveOutcome.saved(BackupStatus, PublishedBook)`.

```swift
if case .saved(_, let published) = try package.save(book) {
    let report = keeper.keep(published, now: .now)
}
```

`PublishedBook`'s initializer is `fileprivate` to `BookPackage.swift`, so nothing else can
make one. In Rust you'd get the same effect from a struct with a private field and no
public constructor. Returning it, rather than calling the keeper from inside `save`, leaves
the store (#11) to decide where and in what order `keep` runs: off the main actor (a due
snapshot flushes two files, about 60 ms), serialized per book like its saves.

### The schedule is a pure function

[`SnapshotSchedule`](../../Sources/SceneItCore/Persistence/SnapshotSchedule.swift) sees
only dates:

- **Cadence:** `decision(snapshots:now:)` is `.due` when there's no snapshot, or the newest
  is at least 10 minutes old. Autosave every 2 seconds still makes at most one snapshot
  per 10 minutes.
- **Retention:** `toDelete(_:now:)` puts each snapshot in a bucket (a 10-minute window, a
  UTC day or a week) and keeps the **oldest** in each. Buckets are aligned to the Unix
  epoch, so a day is made of whole 10-minute windows and a week of whole days.
- **Which tier:** the finest one that still holds the *end* of the snapshot's bucket: a
  window until it ended 24 h ago, a day until it ended 30 days ago. Going by the
  snapshot's own age would split a day that straddles the 30-day line: its first snapshot
  would turn weekly (and usually be pruned) while the rest of its day was still daily, and
  the rest had already been pruned as not-first. By the bucket's end, a day keeps its
  first snapshot until all of it is older than 30 days.
- **The newest is always kept**, and so is the newest at or before `now`.
- **Clock skew:** a snapshot dated after `now` is never deleted and doesn't count for the
  cadence (otherwise a clock set back a year would stop snapshots for a year). Once the
  clock passes it, it's tiered like any other.

Because these are pure, the tests can be exhaustive about boundaries (exactly 10 minutes,
a window or day ending exactly 24 h or 30 days ago, the last second of a window) and check
properties: over random sets, applying `toDelete` to what it kept deletes nothing more;
and over 150 simulated days of saves in six eras (1970, before 1970, a leap day, 2038,
2100, 9999), pruning after every save, an independent whole-seconds model checks that
every week, and every day and window still in its tier, keeps its first snapshot.

### Never fail the save

`keep` doesn't throw. Each destination lists its folder, decides, prunes and writes on
its own, and the result is a `SnapshotReport` holding a `SnapshotOutcome` for each:
`.written`, `.notDue` or `.failed(SnapshotFailure)`, which names the step and the
`FileSystemError`. Every failure is also logged (metadata only, never a path). By the time
`keep` runs, `book.md` is already saved (ADR 0019). If two `keep`s race to write the same
snapshot name, the loser finds the same bytes there and counts it as written.

Pruning only removes regular files whose names round-trip exactly through `SnapshotName`:
`book-20261101T143005Z.JSON`, `notes.txt`, a directory, link or pipe with a snapshot's
name, and the hidden temporary files are never touched. The new `FileSystem.contents(of:)`
reports each entry's kind from `readdir`'s `d_type`, so this costs no extra system calls.
If `Backups/` or the book's mirror folder is itself a symbolic link (or not a folder), that
destination reports `.notARealFolder` before anything in it is read or written: through a
link, `book-id` could be another book's, and pruning could reach outside the package.

When a snapshot is due, each destination also sweeps its folder of the temporary files an
interrupted `keep` left (§6), after the folder check and whatever happens to the snapshot.
Strays must be 10 minutes old and snapshots are at least 10 minutes apart, so sweeping only
when one is due costs at most one extra listing per 10 minutes, not one per autosave. A
read-only book never gets this far: `BackupKeeper` needs a `BookPackage`, which only an
editable book has.

### The book's id, and copied packages

The mirror folder is named by the UUID in `Backups/book-id`, created the first time it's
needed and written like everything else (temporary file, then rename). If it's corrupt, the
book gets a new id and therefore a new, empty mirror folder; the old folder is kept, never
pruned again, and still holds the earlier history. If it can't be *read* (permissions, an
I/O error), it's left alone and the mirror reports a failure: replacing an id we
couldn't read would orphan the mirror on every transient error.

A copied package (Finder's Duplicate, or a drive cloned file by file) carries its
original's `book-id`, and without care both would write into one mirror folder, where
pruning across two diverged histories could delete one's only snapshot. So each mirror
folder records, in `package.json`, the package that writes to it: its path and its
`FileIdentity`, the volume's UUID and the directory's inode. A path names a place; an
identity names the directory itself, which keeps it when renamed or moved within its
volume, while a copy gets a new one. The rule:

| Identity | Path | Meaning | Result |
| --- | --- | --- | --- |
| same | same | this package | use the folder |
| same | different | moved or renamed on its volume | record the new path |
| different | same | another directory where this package was (a clone mounted under the same name, a restore) | new id, new folder |
| different, or unknown | different | read the recorded path's `Backups/book-id`: | |
| | | nothing there, or another id: moved to another volume, or the original is gone | record ours, keep the folder |
| | | the same id, or unreadable: a copy | new id, new folder |
| unknown | same | a volume without UUIDs: only the path can tell | use the folder |

The rule errs towards forking: a wrong fork only starts a new folder (the old one keeps
the history), while a wrong "moved" would mix two books' snapshots. A copy keeps the
history it was copied with: its own `Backups/` still holds the original's snapshots, and
the original's mirror folder holds them too; only the copy's *new* mirror folder starts
empty. Known false forks: a sync service that re-creates the package directory (a new
inode at the same path) starts a new folder each time it does that.

The recorded path is read only when the identity can't decide, which is when the package
moved to another volume or its volume has no UUID. That read can touch another volume, so
macOS may ask the writer for permission to access a removable or network volume once.

### Rust comparison

The keeper is a plain `struct` holding `any FileSystem`, like `struct Keeper { fs: Box<dyn
FileSystem> }`. `SnapshotFailure` is a typed error enum, and `keep` returns it inside the
report rather than as `Result::Err`, because it isn't a failure of the call: the save it
follows succeeded.

## 12. Locks: one app, one writer per book

[ADR 0020](../decisions/0020-instance-and-book-locks.md) adds two locks. Both are
`flock(2)` locks, held for as long as a file stays open.

| Lock | File | Held by | When it's taken elsewhere |
| --- | --- | --- | --- |
| app-wide | `~/Library/Application Support/Scene It/instance.lock` | the running app, for its whole life | the new launch passes its books to the running one and quits |
| per book | `My Novel.sceneit/.lock` | the `BookPackage`, while the book is open | the book opens read-only |

### `flock` against a lock file

There are two ways to say "I'm using this":

- **A lock file whose existence is the lock** (`O_CREAT | O_EXCL`, delete on exit). If the
  process crashes, the file stays, and the next launch has to guess whether its owner is
  still alive ("stale lock, break it?"). Guessing wrong means two writers.
- **A lock on an open file** (`flock`). The kernel ties the lock to the open file, and
  drops it when the last descriptor for it is closed, which happens however the process
  ends: `exit`, a crash, `kill -9`, a power cut (after which nothing is held at all). A
  lock is never stale, so there's nothing to break and nothing to ask the writer.

Scene It uses only the second kind. The file is just something to lock: it's opened with
`O_CREAT` (and never `O_TRUNC`), and it's empty unless it's on a network volume.

`flock` is *advisory*: it only stops other `flock` callers. Finder, a text editor or a sync
service can still change the book, which is why §7's external-change checks stay.

The lock belongs to the *open file description* (what one `open` call creates), not to
the process. Two `open`s of the same file in one process are two descriptions, and the
second `flock(LOCK_EX | LOCK_NB)` fails with `EWOULDBLOCK`, exactly as it would in another
process. That's what makes the in-process tests meaningful.

### The Swift type

```swift
public struct ExclusiveFileLock: ~Copyable, Sendable {
    let descriptor: Int32
    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
    public static func acquire(_ file: URL) -> LockAttempt
    public consuming func release() {}
}

public enum LockAttempt: ~Copyable, Sendable {
    case acquired(ExclusiveFileLock)
    case heldElsewhere
    case failed(FileSystemError)
}
```

`~Copyable` is Swift's opt-out from implicit copying: a value has one owner, moves on
assignment, and runs its `deinit` when its owner is done with it, like a Rust type without
`Clone`. So this is the Swift spelling of `fd_lock::RwLockWriteGuard`, or of the `File`
you called `fs2::FileExt::try_lock_exclusive` on: drop it and the lock is gone.
`consuming func release()` is `drop(guard)`. A `final class` would also close on `deinit`,
but every copy of a reference keeps it alive, so the lock's lifetime would be whatever the
last reference happens to be.

Three details from Rust carry over directly:

- **`O_CLOEXEC`.** Without it, a child process started while the lock is held (a helper,
  `ditto` for a report) inherits the descriptor, and with it the lock, which then outlives
  the app. Rust's standard library sets `O_CLOEXEC` on every file it opens, so you never
  had to think about it; in Swift calling `open(2)` directly, you do.
- **`LOCK_UN` before `close`.** `O_CLOEXEC` closes the child's copy at `exec`, not at
  spawn: while another thread is spawning a process, that child briefly holds a copy of
  every descriptor. A `flock` belongs to the open file, and `close` releases it only when
  the last copy goes, so a lock dropped mid-spawn lingers until the child's `exec`.
  `LOCK_UN` releases it at once, whoever else holds a copy. Rust's `fd_lock` guard does
  the same in its `Drop`.
- **Never delete the lock file.** Process A opens `.lock` and is about to `flock` it.
  Process B, finishing, unlinks it. Process C creates a *new* `.lock` and locks it. A's
  `flock` succeeds too, on the old, now nameless file. Both believe they hold the lock.
  Leaving the file in place costs an empty file; deleting it costs exclusivity.

### Opening a book

```swift
public enum OpenedBook: Sendable {
    case editing(EditableBook)              // has a BookPackage, so it can save
    case readOnly(ReadOnlyBook, ReadOnlyReason)   // a layout and a Book, nothing else
}
```

Only `BookPackage` has `save`, and its initializer is private to the path where the lock
was acquired. A `ReadOnlyBook` holds no package, so there is no expression that saves it:
"read-only" is a type, not a flag the store has to remember to check. `create` returns an
`EditableBook` directly, and takes the lock before writing anything into the new folder.

The lock lives inside the `BookPackage`, so it's released when the last reference to the
package goes. Swift may release a reference as early as its last use, not at the end of the
scope, which is why the tests write `_ = consume package` (Swift's explicit `drop`) or
`withExtendedLifetime` when the timing matters.

The release clears a `LockRecord` (below) and flushes it to the drive, so the store
should drop its last reference off the main actor.

The lock belongs to the package, not to the process. Opening a book this process already
has open gives `.openElsewhere`, so the store must reuse the package it has (or release it
first), for example for ADR 0018's "Open Other Version".

`open` reads `book.md` before taking the lock, then reads it once more under the lock;
if it changed in between, it's loaded again. If it no longer loads, the lock is released
and the open fails like any other load; if it now needs a repair (§13), the lock is
released and the book opens read-only.

`ReadOnlyReason` says why: `.openElsewhere` (the `flock` is held: another user account, or
a copy that didn't go through the app lock), `.lockUnavailable(error)` (a read-only disk,
or a folder without write permission, where a save would fail anyway),
`.openOnAnotherMac(record)` and `.openInAnotherProcess(record)` (below), or, from the
contents rather than the lock, `.repairedOnOpen(repair)` and `.newerFormat(version)` (§13).
The words the writer sees are in `ReadOnlyWording`.

### The app-wide lock

`AppDelegate.applicationWillFinishLaunching` runs before any window, and the first thing it
does is `LaunchGate.open`:

```swift
let launch = LaunchGate.open(
    role: .current, acquire: { LaunchGate.acquire(SupportFolder.instanceLock) },
    startSession: { diagnostics.start() })
```

`startSession` writes the crash marker of [chapter 11](11-crash-reporting.md), and the gate
calls it only once the lock is settled, so a second instance never touches the first one's
marker. The marker's own `anotherInstanceRunning` check stays as a backstop. If the lock
is held, the launch collects the books AppKit hands it (`application(_:open:)` arrives
before `applicationDidFinishLaunching`), passes them on with
`NSWorkspace.open(_:withApplicationAt:configuration:)` naming the *running* app's bundle,
which makes Launch Services deliver them to that process, activates it, and quits. The
running instance is found by the process id the holder wrote into `instance.lock`, or, if
that isn't a running Scene It, by bundle id (`LaunchGate.handOffTarget`, a pure function).

`ProcessRole` reads the environment: under XCTest or a SwiftUI preview the gate never asks
for the lock, so `scripts/check.sh` works while the writer has Scene It open. The same
predicate keeps diagnostics in a temporary folder.

### Network volumes, and volumes without `flock`

On SMB and NFS shares, a `flock` taken on one Mac isn't reliably seen by another. Some
volumes (NFS mounted `nolocks`, some FUSE file systems) don't support `flock` at all and
fail it with `ENOTSUP`; `ExclusiveFileLock` then reports `enforcement == .none` instead of
failing, because forcing every book on such a volume read-only would make it unusable. In
both cases the book lock also writes a `LockRecord` into `.lock`:

```json
{ "host" : "Samit's MacBook Pro", "hostID" : "…hardware UUID…", "userID" : 501, "processID" : 812, "since" : "2026-11-01T14:30:05Z" }
```

Opening checks it with a pure function, `LockRecord.blocking(_:opener:policy:)`. The
`Opener` (this Mac, user, process, and a liveness check) is injected, so tests can play
several processes:

- no record, or one that isn't valid JSON: free;
- a record from **this** Mac: blocks while its process is alive and isn't the opener's own
  (`kill(pid, 0)` succeeding, or failing with `EPERM` because the process is another
  user's). A dead process's record is a crash leftover: free. That's
  `.openInAnotherProcess(record)`;
- a record from another Mac: read-only, `.openOnAnotherMac(record)`, however old it is. A
  writer may keep a book open for days, so a record never expires on its own; a crashed
  Mac's leftover costs one "Open Anyway".

"Open Anyway" reopens with `LockRecordPolicy.openAnyway(record)`. That overrides exactly
the record the writer saw; a newer one is respected again, the same pattern as §7's
`overwriteKeepingTheirsAsBackup(theirs:)`.

The record is written over the old contents and then truncated to its length, so another
reader never finds the file empty in between. A package that wrote a record clears it
again when it's released, while it still holds the lock, and only if the record is still
its own. If `.lock` can't be opened for writing, it's locked through a read-only
descriptor (`flock` doesn't need write access), and only the record is skipped.

This is advisory twice over, so §7's digest check remains the backstop: if two Macs both
end up editing, each save still refuses to replace a `book.md` it didn't write.

### Rust comparison

| Swift | Rust |
| --- | --- |
| `ExclusiveFileLock.acquire(url)` | `fd_lock::RwLock::new(file).try_write()`, or `fs2::FileExt::try_lock_exclusive` |
| `.heldElsewhere` | `Err(e) if e.kind() == WouldBlock` |
| `~Copyable` + `deinit` | a type without `Clone`, with `Drop` |
| `consuming func release()` | `drop(guard)` |
| `switch consume attempt { case .acquired(let lock): … }` | `match attempt { Ok(guard) => … }`, moving out of the enum |

## 13. Damaged books: read-only until the original is safe

The format-2 parser never fails (chapter 02), which creates a new danger. A `book.md` that
a sync tool emptied, truncated or re-encoded opens as a *repaired* book: maybe an empty
one. If it opened for editing, autosave would write the repair over the file, and after
three more saves the damaged original would have rotated out of `bak1…3`. Snapshots don't
help either: they copy only what Scene It wrote. Whatever the writer could have recovered
by hand from the damaged file would be gone.
[ADR 0024](../decisions/0024-damaged-books-open-read-only.md) closes that window.

### Which books open read-only

`BookFormat.parse` reports `ParsedBook.newEntries`: the error entries *this* parse made.
Entries the file already carried in `### Unparsed` (from an earlier session the writer
hasn't cleaned up) aren't new, so they don't count. `open` decides from the contents first,
before it takes the lock:

```swift
        var readOnlyReason: ReadOnlyReason? {
            if parsed.isNewerThanSupported, let format = parsed.declaredFormat { return .newerFormat(format) }
            guard parsed.wasRepaired else { return nil }
            return .repairedOnOpen(Repair(newEntries: parsed.newEntries, original: data))
        }
```

- **`.newerFormat(version)`** (format §10 Q7): a `format: 3` file from a newer Scene It.
  This version would save it as format 2, losing what it doesn't understand, so it stays
  read-only. There's no way to edit it here, and the order matters: a newer file also
  gets a notice (a new entry), and the newer format must win so that Make Editable is never
  offered.
- **`.repairedOnOpen(repair)`**: the parse made new entries. `Repair` carries them (for the
  alert, and later the Errors tab, #63) and, internally, `original`: **the exact bytes that
  were parsed**.

### Make Editable

Make Editable is two calls, and the type system orders them:

```swift
    public static func keepOriginal(
        of repair: Repair, now: Date = .now, fileSystem: any FileSystem = LocalFileSystem()
    ) throws(FileSystemError) -> KeptOriginal

    public static func edit(
        _ kept: consuming KeptOriginal, onLockRecord policy: LockRecordPolicy = .respect,
        fileSystem: any FileSystem = LocalFileSystem()
    ) -> MadeEditable
```

1. `keepOriginal` writes `repair.original` through the usual durable path
   (`writeTemporary`, flushed with `F_FULLFSYNC`, then a rename that never replaces
   anything) to `book.md.original-<UTC time>.md`, with `-2`, `-3`, … if that name is taken
   (the shared `publishUnderFreeName`). It returns a `KeptOriginal`.
2. `edit` consumes that `KeptOriginal`, takes the lock as `open` would, and returns an
   editable book whose package believes it last read the original's bytes. If the lock
   can't be had, `MadeEditable.readOnly` hands the `KeptOriginal` back with the reason, for
   another try.

Three types make the order the only one that compiles:

- `Repair`, the payload of `.repairedOnOpen`, holds the package's layout, the book and the
  bytes together, and its initializer is `fileprivate`: only `open` makes one. So
  `keepOriginal` can't be handed one book's bytes and another book's package.
- `KeptOriginal`'s initializer is `fileprivate` too, so the only way to get one is a
  successful `keepOriginal`, and the only way into `edit` is with one. "The first save
  happens only after the original is on disk" isn't a convention the store has to remember.
- `KeptOriginal` is `~Copyable` and `edit` takes it `consuming`, so one kept original makes
  at most one editable package: using it twice is a compile error ("'kept' used after
  consume"), not a runtime check.

In Rust this is a *witness* or *proof token*: a struct with a private field and no `Clone`,
returned only by the function that did the work and taken by value by the next one.
`MadeEditable` is the `Result<EditableBook, (KeptOriginal, Reason)>` that gives the token
back on failure.

**Why the bytes come from the open, not a second read.** Between showing the read-only
book and the writer clicking Make Editable, another program can change `book.md`. Reading
it again would keep a version the writer never saw as the "original", and the package would
then silently believe the new version was its own. Instead, `edit` sets the package's
`lastSeen` digest to the *kept* bytes. If `book.md` changed in the meantime, the first
save finds a digest it doesn't recognize and stops with ADR 0018's "changed on disk",
exactly as for any other external change. The test
`theOriginalIsTheBytesThatWereParsedNeverALaterVersion` does precisely this.

**Why nothing ever removes it.** Each thing that removes files in a package only looks at
names it owns:

| Mechanism | What it touches | `book.md.original-…md`? |
| --- | --- | --- |
| Rotation | `book.md.bak1…3` (`BackupSlot`) | no |
| Snapshot pruning | names `SnapshotName(fileName:)` accepts, in `Backups/` | no: wrong prefix and folder |
| Stray-file sweep | `.<destination>.<UUID>.tmp`, for `book.md`, `bak1` and an original | no: it isn't a temporary name |

An original whose own temporary file was orphaned by a crash (`.book.md.original-<time>.md.<UUID>.tmp`) is swept like a
save's: it holds the bytes `book.md` held when it was written, so it's removed only if `book.md`, a backup or a
snapshot holds exactly those bytes, and otherwise renamed to `book.md.recovered-<time>.md`.

The tests plant it among the sweep's and the pruning's decoys, and one test runs 120 saves
with snapshots over 40 simulated days (with pruning and a sweep) and checks the original is
still byte-for-byte the damaged file, long after the rotation has dropped it.

**After Make Editable** the store marks the repaired book unsaved, so autosave writes it:
the notices the parse made go into `### Unparsed`, and the next open finds them already
there, not new, and opens for editing. If the lock can't be had (the book is open
elsewhere), the original is kept anyway and the book stays read-only with its
`.repairedOnOpen` reason, so the writer can try again.

### In the store and the app

`BookStore.open` shows the read-only alert from `ReadOnlyWording`. For `.repairedOnOpen` it
offers **Keep Read-Only** (first, so it's the default) and **Make Editable**;
`.newerFormat` offers only Keep Read-Only. `BookStore.makeEditable()` runs the two steps off
the main actor and then switches the open book to editing in place
(`OpenBook.becomeEditable`), keeping the selected scene. The owner approved the wording; a
persistent banner and File → Make Editable… (#67) will call the same operation.

### Rust comparison

| Swift | Rust |
| --- | --- |
| `KeptOriginal: ~Copyable` with a `fileprivate init` | `pub struct KeptOriginal { _private: () }` (no `Clone`), returned only by `keep_original` |
| `edit(_ kept: consuming KeptOriginal) -> MadeEditable` | `fn edit(kept: KeptOriginal) -> Result<EditableBook, (KeptOriginal, Reason)>` |
| `ParseDefaults` holding `@Sendable` closures | a `Send + Sync` struct of `Arc<dyn Fn() -> … + Send + Sync>` |

## 14. The archive: filed copies that never change

File a Copy (PLAN §5.5, §7.1) keeps a version of the whole book forever: `Archive/saveNNNN.md`, an
exact copy of `book.md`, plus `Archive/index.md`, which holds everything editable about each copy
(tags, the date the writer gave, a note, and cached counts). The code is
[`Archive.swift`](../../Sources/SceneItCore/Persistence/Archive.swift) (the file operations) and
[`ArchiveReconciliation.swift`](../../Sources/SceneItCore/Persistence/ArchiveReconciliation.swift) (the
pure part).

### Filing, step by step

`BookPackage.fileCopy(of:as:)` does it all under the package's mutex, so no save can slip in between:

1. **Save first.** The book is serialized and verified, then saved exactly as autosave would (refusing
   another program's version). The store has already asked autosave to save and waited
   (`AutosaveDriver.saveAndWait`, the same wait as quitting), so this save is usually `.unchanged`.
2. **Read `book.md` back** and require it to hold exactly the verified bytes. Those bytes are what's filed.
3. **Write the copy** with `writeTemporary` (a hidden file, flushed with `F_FULLFSYNC`), **read the
   temporary file back** and compare, then `publish` it as `saveNNNN.md`. `publish` is
   `renamex_np(RENAME_EXCL)`: it fails rather than replace anything, so if another filing took the number
   meanwhile, the next number is tried. A copy that doesn't read back correctly never gets a name.
4. **Lock it**: `lchflags(UF_IMMUTABLE)` (Finder's "Locked", `chflags uchg`), then `lstat` to check that
   the flag is really there. APFS, HFS+, FAT and exFAT all keep the flag on macOS 27; a volume without it
   (some network shares) refuses, and a volume could accept it and keep nothing. Either way the filing still
   counts (the copy exists), but the outcome says `.notLocked`, and the writer is told. A check that fails
   after the flag was set is `.unverified`, never "not locked". A crash between publishing and locking
   leaves an unlocked copy; the next open of the book for editing locks it.
5. **Update the index**: read and parse it, reconcile it with the folder (below), give the new copy its
   section, verify the serialization (as for `book.md`), and replace `index.md` atomically. If that fails,
   the copy is still there, and the next reconciliation lists it (without the tags and note, which are
   reported as lost).

Only steps 1–3 can fail the filing; each failure leaves no new file in `Archive/`. The outcome is a value
with a field per later step (`FilingOutcome.lock`, `.index`), so a half-success can't be mistaken for a
full one.

### Reconciliation is a pure function

`ArchiveReconciliation.reconcile(listing:index:modified:counts:)` takes the directory listing and the parsed
index and returns what the File Cabinet lists, plus notices:

- a `saveNNNN.md` with no section is listed with no tags, its counts computed by parsing the copy read-only;
- a section whose file is gone is dropped;
- the next number is one more than the highest file, whatever the gaps;
- anything that isn't a regular file named exactly `saveNNNN.md` is ignored;
- an index whose `format:` is newer than this version is never rewritten (`.refused(newerFormat:)`), as
  ADR 0024 does for books.

The function never touches the disk: the modification day and counts come in as closures, so the tests feed
it dictionaries. The impure wrapper, `Archive.reconcile`, runs it when a book opens; it saves the index only
when the book is editable (its lock is held) and something changed, and never when `index.md` couldn't be
read: an index Scene It can't read may hold tags it would otherwise overwrite.

### The dialog, and what the writer typed

[`SceneIt/Window/FileACopy.swift`](../../SceneIt/Window/FileACopy.swift) holds the dialog
(labels in a column, the archive box by the title, as the owner chose in #32), the toast
above the status bar, and `FilingFlow`, which owns both for one window. The draft is
`FilingDraft` in the core, so its rules (Return adds a chip, ⌫ in an empty field removes the
last, a repeated tag is ignored) are unit-tested without a window.

Text typed in the dialog goes through the same character policy as the page (ADR 0028). The
tag field's field editor and the note are `AdmittingTextView`s: `KeyboardTextView`s with no
input method that veto a change they can't hold and make its admitted reading instead, the
same class the scene title uses. `FilingDraft` admits again on every assignment, so the model
can't hold what `index.md` won't keep.

The dialog's contents are the open book's `filingDraft`, so leaving the book sees them:
quitting and closing the book each call `OpenBook.confirmLeaving` once, before saving, which
asks "Quit without filing the copy?" (or "Close…") when tags or a note are typed, with Cancel
as the default. Choosing to leave doesn't clear the draft: it goes with the book only if the
book is really left, so a save that then fails, and the writer's Cancel, loses nothing. A book read
again in place (Open Other Version, Open My Version, Open Anyway) isn't left: `BookStore.install` hands
the new `OpenBook` the old one's draft, so the rebuilt window puts the dialog back up as it was (#146). File copy names the book it files (`fileACopy(of:as:)`), so one pressed in the old dialog and queued
behind the reload files nothing, silently: the draft is waiting in the new dialog. The book window's first responder stays the page while the sheet is up, so
`UndoStack` takes a `dialog` input: while one is attached, Undo acts only on a text field in
it, never on what's behind.

The dialog stays up, and not editable, until the copy is filed, so a failure loses nothing typed. If the copy is
filed but the index can't be written, the open book keeps the record as pending, and the next
save or filing writes it. A reload doesn't drop it (#148): Open Other Version tries the write once
more before it lets go of the book, the book read again in place takes what's still pending, and
its opening reconciliation records it. Open My Version switches to another package, whose Archive
has none of the original's copies, so whatever the last try couldn't write is quoted in a notice.
Closing or quitting tries once more and quotes what's left the same way, and so does a reload that
fails to open. If another program has given the copy a section of its own meanwhile, that section is
kept, never overwritten, and the record is quoted instead. Every alert that might lose text quotes the tags and note back.

### Three layers keep a filed copy unchanged

1. **Nothing writes there.** Rotation, snapshots, pruning and the stray-temporary-file sweeps only list the
   package root and `Backups/`; the tests plant decoys in `Archive/` (snapshot names, temporary-file names,
   `book.md.bak1`) and run all of them for real. An unfinished "my edits" copy that holds a filed copy isn't
   removed.
2. **The seam refuses.** `LocalFileSystem.remove`, `move` and `exchange` throw `.filedCopy` for any
   `Archive/saveNNNN.md` (`PackageLayout.isFiledCopy`), even on a volume that can't lock it.
3. **The kernel refuses.** With `UF_IMMUTABLE` set, `unlink`, `rename` over it and opening it for writing
   all fail with `EPERM`, whoever asks, the owner included, until the flag is cleared
   (`chflags nouchg save0001.md`). Tests clear it the same way before deleting their temporary folders.

### Rust comparison

| Swift | Rust |
| --- | --- |
| `lchflags(path, flags \| UF_IMMUTABLE)` | `nix::sys::stat` has no `chflags`; call `libc::lchflags` |
| `FilingOutcome { lock: CopyLock, index: IndexUpdate }` | a struct of two enums rather than `Result<_, _>`: the copy already exists |
| `ArchiveReconciliation.reconcile(…, counts: (FiledCopyNumber) -> FiledCopyCounts?)` | `fn reconcile(…, counts: impl Fn(FiledCopyNumber) -> Option<Counts>)` |
