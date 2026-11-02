# 03 — Saving safely

How a book gets onto disk without ever being lost or half-loaded, explained for someone
who has written `tempfile` + `persist` in Rust.

The rules come from [WORKFLOW.md](../dev/WORKFLOW.md)'s trust section: never write
`book.json` without encode → verify → rotate → atomic write; a failed load never
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

`BookPackage` is a `final class`, not a struct. It remembers a digest of the
`book.json` it last read or wrote (§7), and two copies of a struct could each remember
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
or `.saved(BackupStatus)`. `BackupStatus` is `.intact`, or
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
            let current = try readCurrent(lastSeen, policy)
            if current?.data == data {
                Log.store.debug("book unchanged; nothing saved")
                return .unchanged
            }
            let backups = try replaceBook(with: data, current: current, &lastSeen)
            lastSeen = ContentDigest(data)
            Log.store.info("saved the book", ["bytes": .bytes(Int64(data.count))])
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
3. **Read `book.json`, and decide whose it is.** Refuse a read-only or locked file (§8).
   Compare the bytes' digest with the one remembered: equal means *ours*, otherwise
   *theirs*, which `.refuse` turns into an error (§7).
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
What happens next depends on whose version `book.json` holds:

| `book.json` holds | The rotation fails | Result |
| --- | --- | --- |
| our own last save | at any step | **Save anyway**: `.saved(.previousVersionNotBackedUp(error, olderBackups:))`. The new book contains the old one plus the edits; refusing would leave the session's typing only in memory. The store shows "Backups aren't working". |
| another program's version (`.overwriteKeepingTheirsAsBackup`) | at any step | **Refuse**: `SaveError.couldNotBackUpTheirVersion`. Nothing is published, and their version stays in `book.json`. |

Other details:

- **A missing slot absorbs the shift.** A missing `bak2` is `.notFound` and is skipped,
  so `bak3` keeps its version. A missing `bak1` means nothing shifts at all. A retry
  after a crash fills the gap instead of discarding another version.
- **`bak1 == book.json` means "already backed up".** If the final rename failed, `bak1`
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
- **`exchange`** swaps two names in one step (`RENAME_SWAP`). It's used for `book.json`
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

- **Permissions** follow Foundation: the new `book.json` gets the old one's permission
  bits. The new `bak1` gets `book.json`'s bits too, not the old `bak1`'s, so a private
  (0600) book keeps private backups, and an unreadable old `bak1` doesn't make the new one
  unreadable. Older backups keep the bits they had, so a change to `book.json`'s
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
  write into the same file. A crash can leave a hidden `.book.json.<uuid>.tmp` behind.
  Nothing reads it; cleaning these up is issue #49.

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

Start from a package where `book.json` is version V0 (our own last save) and the
backups are V1–V3, and save V9. Each row is the state on disk if the process dies right
after that step. Every step is either in memory, a read, a durable write under a hidden
name, or a rename, so there are no torn states between rows, at worst a stray temporary
file.

| Crash after | `book.json` | `bak1` | `bak2` | `bak3` | Opens as |
| --- | --- | --- | --- | --- | --- |
| encode, verify, the checks, the reads | V0 | V1 | V2 | V3 | V0 |
| writing the temporary `bak1` and `book.json` | V0 | V1 | V2 | V3 | V0, plus stray temporary files |
| `bak2` → `bak3` | V0 | V1 | — | V2 | V0 |
| `bak1` → `bak2` | V0 | — | V1 | V2 | V0 |
| publishing `bak1` | V0 | V0 | V1 | V2 | V0 |
| exchanging `book.json` | V9 | V0 | V1 | V2 | V9 (V0 also at a stray temporary name) |

- **`book.json` is always present and whole**, and it's V0 or V9.
- **Nothing but V3 is ever lost**, and V3 is the version this save retires anyway.
- **The next save repairs the gaps.** In every row, saving V9 again ends with
  `bak1`–`bak3` = V0, V1, V2.

Errors (as opposed to crashes), when `book.json` holds our own last save:

| Failing step | Result | `book.json`, `bak1`–`bak3` afterwards |
| --- | --- | --- |
| encode, verify, inspecting or reading `book.json` | throws; nothing changed | V0; V1, V2, V3 |
| writing either temporary file (full disk, I/O) | throws; nothing changed | V0; V1, V2, V3 |
| inspecting or reading `bak1` | treated as "different"; saves normally | V9; V0, V1, V2 |
| `bak2` → `bak3` | `.saved(.previousVersionNotBackedUp(_, .untouched))` | V9; V1, V2, V3 |
| `bak1` → `bak2` | `.saved(.previousVersionNotBackedUp(_, .oldestRetired))` | V9; V1, —, V2 |
| publishing `bak1` | `.saved(.previousVersionNotBackedUp(_, .oldestRetired))` | V9; —, V1, V2 |
| exchanging `book.json` | throws; retries don't rotate again | V0; V0, V1, V2 |
| reading the displaced file after the exchange | swapped back; `.externallyModified(.changed)` | V0; V0, V1, V2 |

When `book.json` holds another program's version (saving with
`.overwriteKeepingTheirsAsBackup`), the three rotation rows throw
`.couldNotBackUpTheirVersion` instead, and `book.json` keeps their version.

## 7. Noticing someone else's changes

Dropbox, `git checkout` or a text editor can replace `book.json` while the app has
it open. Saving over that would silently throw their version away. So `BookPackage`
remembers a SHA-256 digest of the `book.json` it last read or wrote, and a save compares
the digest of what's there now. The bytes are read anyway (for the unchanged check and
the backup), so there's no cheaper signal worth trusting more: size and modification time
can be restored by a careful writer, and one of the tests does exactly that.

```swift
            if ContentDigest(data) == lastSeen { return Current(data: data, owner: .ours) }
            guard policy == .overwriteKeepingTheirsAsBackup else { throw refusal(.changed) }
            return Current(data: data, owner: .theirs)
```

- A **touched** file, or one **copied back with identical bytes**, is still ours.
- A **changed** file throws `SaveError.externallyModified(.changed)`, and a removed one
  throws `.removed`, unless the caller passes
  `onExternalChange: .overwriteKeepingTheirsAsBackup`. With that policy, the other
  program's version is rotated into `bak1` first (and the save is refused if that fails,
  §4), and a removed `book.json` is recreated.
- Anything that **isn't a file** (a directory or a link where `book.json` was) is
  `.notAFile` and is refused under either policy.

ADR 0018 decides what the writer sees.

### A write that lands during the save

The check above happens before the temporary files are written. Another program could
write `book.json` after it, and a plain rename would then replace their version without
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
                throw error.cause == .alreadyExists ? refusal(.changed) : .fileSystem(error)
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
        throw refusal(.changed)
    }
```

After the swap, the temporary name holds whatever `book.json` held *at the instant of the
swap*. If those aren't the bytes the save checked, another program renamed a new version
into place in between, and a second swap puts their version back. The save then throws `.externallyModified(.changed)`,
which leads to ADR 0018's choice like any other external change. Swapping back, rather
than keeping their bytes under another name, leaves the package exactly as the other
program meant it, and needs nothing new from the store.

Two fallbacks remain, each documented in code:

- **The swap back fails** (a double fault). Their version is renamed to
  `book.json.conflict-<UTC time>` (with `-2`, `-3`, … if that name is taken), and the save
  throws `.externallyModified(.keptAsConflict(fileName:))`. If even that rename fails, the
  error names the hidden temporary file that holds it. The package then records the digest
  of the bytes *this save* wrote, never a fresh read of `book.json`: a third write landing
  at that moment would otherwise be taken for ours, and a later save could replace it
  without a backup. A regression test injects exactly that triple fault.
- **The volume can't swap** (FAT, exFAT, HFS+). The save re-reads `book.json` just
  before a plain rename. A write landing in the microseconds between the two is the one
  residual window.

Where the volume can swap, this closes the window for writers that **rename a new
version into place**, which is what sync services and most editors do. A writer that
already had `book.json` open and **edits it in place** can still write into the displaced
file after the comparison, and that write is lost when the file is discarded. That window
is small, and closing it would need a lock. It isn't a lock either way: two copies of the
app saving the same book will keep refusing each other's changes, which is the intended
outcome. ADR 0005 leaves real locking for later.

## 8. Permissions and locks

A save would succeed on a read-only (0444) or locked `book.json`, because a rename only
needs permission on the *directory*. That would silently undo the writer's protection, so
the save refuses with `SaveError.writeProtected(.readOnly)` or `(.locked)` before writing
anything. `.locked` covers Finder's "Locked" (the immutable flag) and the append-only
flag, both of which make the final rename fail anyway. A writable file has no protection
value at all (`FileItem.file(_, protection: nil)`), so there's no "write-protected:
writable" state to handle.

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
}
```

These are exactly the operations create, open and save use. `publish` and `exchange`
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
call, which is how the tests play "another program writes `book.json` mid-save". Its
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
  `book.json` holds their version, and checks that nothing is published.
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
  replaced by a directory; a read-only, locked or append-only `book.json`; permissions
  kept across a save.
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
- **Mutation checks.** Removing the "theirs must be backed up" guard, the swap-back, or
  the stop-at-first-failure rule each makes these tests fail.
