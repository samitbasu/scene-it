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
| [`BookPackage.swift`](../../Sources/SceneItCore/Persistence/BookPackage.swift) | create, open and save; the save pipeline; `SaveOutcome` |
| [`PackageLayout.swift`](../../Sources/SceneItCore/Persistence/PackageLayout.swift) | where each file lives in a `.sceneit` package; `BackupSlot` |
| [`FileSystem.swift`](../../Sources/SceneItCore/Persistence/FileSystem.swift) | the file-system protocol (the testing seam), `FileStamp`, `FileSystemError` |
| [`LocalFileSystem.swift`](../../Sources/SceneItCore/Persistence/LocalFileSystem.swift) | the real implementation: POSIX calls, `F_FULLFSYNC` |
| [`PersistenceErrors.swift`](../../Sources/SceneItCore/Persistence/PersistenceErrors.swift) | `SaveError`, `CreateError`, `LoadError`, `EncodingFailure` |

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

## 2. `throws` and typed errors

Chapter 00 §6 introduced typed throws. Persistence is where they pay off: the store
(#11) has to show a different message for "your book is invalid", "the disk is full"
and "another program changed the file", and an exhaustive `switch` over a typed
error makes the compiler check that it handles them all. Each entry point names its
error type:

```swift
    public static func create(
        at url: URL, title: String, fileSystem: any FileSystem = LocalFileSystem()
    ) throws(CreateError) -> OpenedBook {
```

```swift
    public mutating func save(_ book: Book) throws(SaveError) -> SaveOutcome {
```

`SaveOutcome` is `.saved` or `.unchanged`, so the status bar can tell the two apart.

There's no `From`, so every boundary converts by hand. When one function calls
several that each throw `FileSystemError`, a `do`/`catch` infers the error's type
and wraps it once:

```swift
        do {
            try backUp(current)
            lastSeen = try fileSystem.writeAtomically(data, to: layout.book)
        } catch {
            Log.store.error("couldn't save the book", error.logMetadata)
            throw .fileSystem(error)
        }
```

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
    mutating func save(encoded data: Data) throws(SaveError) -> SaveOutcome {
        do {
            try Self.verify(data)
        } catch {
            Log.store.fault("the encoded book failed verification", ["error": .error(LoggedError(error))])
            throw .encoding(error)
        }
        let current = try readCurrentIfUnmodified()
        if current == data {
            Log.store.debug("book unchanged; nothing saved")
            return .unchanged
        }
        do {
            try backUp(current)
            lastSeen = try fileSystem.writeAtomically(data, to: layout.book)
        } catch {
            Log.store.error("couldn't save the book", error.logMetadata)
            throw .fileSystem(error)
        }
        Log.store.info("saved the book", ["bytes": .bytes(lastSeen.size)])
        return .saved
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
3. **Skip unchanged.** If `book.json` already holds these exact bytes, return
   `.unchanged` without touching anything. Autosave runs every couple of seconds;
   if it rotated each time, three idle autosaves would push every real backup out.
4. **Rotate.** Shift the backups and copy the current `book.json` into `bak1` (§4).
5. **Write.** Replace `book.json` atomically and durably (§5).

Every failure is logged through `Log.store` (chapter 11) before it's thrown. The
log gets the operation and cause as fixed symbols (`operation=write cause=other`),
never the path: a path contains the book's title, and the `Log` API only accepts
`StaticString` messages and `LogValue` metadata, so it couldn't carry one anyway.

Before step 3, `readCurrentIfUnmodified` checks that `book.json` is still the file
this package last read or wrote (§7).

## 4. Rotation that never leaves the book missing

PLAN §5.4 says "rotate `bak2`→`bak3`, `bak1`→`bak2`, `book.json`→`bak1`, then write".
Done literally with renames, there's a moment with no `book.json` on disk: between
renaming it to `bak1` and the new one landing. A crash there leaves a book that
won't open. So `book.json` is never moved. It's *copied* into `bak1` with the same
atomic write used for `book.json` itself, from bytes already read in step 3:

```swift
    private func backUp(_ current: Data) throws(FileSystemError) {
        let bak1 = layout.backup(.bak1)
        if try fileSystem.item(at: bak1) != nil {
            // A save that failed after this step leaves bak1 equal to book.json; shifting
            // again on the retry would push a real backup out for a duplicate.
            if try fileSystem.read(bak1) == current { return }
            let bak2 = layout.backup(.bak2)
            if try fileSystem.item(at: bak2) != nil {
                try fileSystem.move(bak2, over: layout.backup(.bak3))
            }
            try fileSystem.move(bak1, over: bak2)
        }
        _ = try fileSystem.writeAtomically(current, to: bak1)
    }
```

Two details matter for repeated failures:

- **A missing slot absorbs the shift.** If `bak1` is missing (a previous save died
  after moving it), nothing shifts; if only `bak2` is missing, only `bak1` moves. A
  retry after a crash fills the gap instead of discarding another version.
- **`bak1 == book.json` means "already backed up".** If the final write failed (a full
  disk, say), `bak1` already holds the current version. Without this check, every
  failing autosave would shift again, and three of them would replace all the
  backups with copies of the current book. The tests caught this: removing the line
  makes the fault-injection tests fail for the final-write step.

A backup's modification time is therefore *when that version was superseded*: the
copy into `bak1` is a new file, and renames keep it. `LoadError` lists those times.

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
`F_FULLFSYNC`. A few milliseconds per autosave is a fine price for a novel.

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
`sync_all` calls are what make it durable.

### What `Data.write(options: .atomic)` does

Foundation's `Data.write` comes from the open-source
[swift-foundation](https://github.com/swiftlang/swift-foundation), which Apple's
Foundation is built on. Reading `Sources/FoundationEssentials/Data/Data+Writing.swift`
(at commit `88028b7`), `.atomic` writes a temporary file, calls plain `fsync` (not
`F_FULLFSYNC`), and `renameat`s it over the target. It does not flush the directory.
On two errors it gives up on atomicity: when `rename` fails with `EINVAL` (FAT
volumes), it swaps names in two steps, and with `EBUSY` it "Tr[ies] again,
non-atomically" by overwriting the target in place.

`FileManager.replaceItemAt` is the other candidate. It's built for document-style
safe saves (it can keep a backup item and preserve metadata), but it documents no
flushing guarantee either, and its behaviour varies by volume type.

So `LocalFileSystem` does it by hand, which is the Rust recipe above in Swift:

```swift
    public func writeAtomically(_ data: Data, to file: URL) throws(FileSystemError) -> FileStamp {
        let directory = file.deletingLastPathComponent()
        let temporary = directory.appending(
            path: ".\(file.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        let stamp: FileStamp
        do {
            stamp = try Self.writeDurably(data, toNewFile: temporary)
            try Self.rename(temporary, over: file)
        } catch {
```

`writeDurably` opens the temporary file with `O_CREAT | O_EXCL`, writes all the
bytes (retrying on `EINTR` and short writes), and flushes:

```swift
    private static func flushToDrive(_ descriptor: Int32, file: URL) throws(FileSystemError) {
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw FileSystemError(.write, file, cause(errno))
        }
    }
```

The `fsync` fallback is for file systems without `F_FULLFSYNC` (SMB and some FUSE
volumes). If `rename` fails, the temporary file is removed and the error is thrown;
there's no non-atomic fallback. After the rename, the directory is flushed the same
way, which makes the rename itself durable. (`F_FULLFSYNC` on a directory descriptor
returns 0 on APFS; that was checked too.) A failure to flush the directory is logged,
not thrown: the new file is already in place, so reporting "the save failed" would be
false.

The temporary name is unique (a UUID), so two processes saving at once can't write
into the same temporary file. A crash can leave a hidden `.book.json.<uuid>.tmp`
behind. It's harmless: nothing reads it.

`writeAtomically` returns the new file's `FileStamp`, taken with `fstat` *before*
the rename. A rename doesn't change a file's modification time, so that's the stamp
`book.json` has afterwards, without a separate step that could fail after the file
was already replaced.

## 6. What a crash leaves behind

Start from a package where `book.json` is version V0 and the backups are V1–V3,
and save V9. Each row is the state on disk if the process dies right after that step.
Every step is either in memory, a read, a `rename`, or an atomic write, so there are
no torn states between rows; at worst there's a stray temporary file.

| Crash after | `book.json` | `bak1` | `bak2` | `bak3` | Opens as |
| --- | --- | --- | --- | --- | --- |
| encode, verify, the stamp check, the reads | V0 | V1 | V2 | V3 | V0 |
| `bak2` → `bak3` | V0 | V1 | — | V2 | V0 |
| `bak1` → `bak2` | V0 | — | V1 | V2 | V0 |
| copying V0 into `bak1` (before its rename) | V0 | — | V1 | V2 | V0, plus a stray temporary file |
| copying V0 into `bak1` | V0 | V0 | V1 | V2 | V0 |
| writing `book.json` (before its rename) | V0 | V0 | V1 | V2 | V0, plus a stray temporary file |
| the rename of `book.json` | V9 | V0 | V1 | V2 | V9 |

So:

- **`book.json` is always present and whole**, and it's V0 or V9.
- **Nothing but V3 is ever lost**, and V3 is the version this save retires anyway.
- **The next save repairs the gaps.** A missing slot absorbs the shift, and an
  existing `bak1 == book.json` stops a second shift (§4). In every row, saving V9
  again ends with `bak1`–`bak3` = V0, V1, V2.

The same holds for errors instead of crashes: at any failing step `book.json` is
untouched, the save throws, and the store can retry.

## 7. Noticing someone else's changes

Dropbox, `git checkout` or a text editor can replace `book.json` while the app has
it open. Saving over that would silently throw their version away. So `BookPackage`
remembers the `FileStamp` (size and nanosecond modification time) of the `book.json`
it last read or wrote, and a save first compares:

```swift
        guard item == .file(lastSeen) else {
            Log.store.error("refused to save over a book.json changed by another program")
            throw .externallyModified
        }
```

A removed file, a rewritten one, a `touch`ed one, and one replaced with identical
bytes (new mtime) all fail with `SaveError.externallyModified`. The store (#11) decides
what to offer the writer. When opening, the stamp is taken *before* reading, so a
change that lands mid-read makes the next save refuse rather than overwrite it.

This doesn't close the race where another program writes between the check and our
rename. Closing it needs a lock, which ADR 0005 leaves for later.

## 8. Loading: all or nothing, and never a write

```swift
    /// Reads, decodes and validates `book.json`, all or nothing. Never writes.
    public static func open(
        at url: URL, fileSystem: any FileSystem = LocalFileSystem()
    ) throws(LoadError) -> OpenedBook {
```

`open` checks the extension, that the package is a directory and `book.json` a
regular file (a named pipe would block a read forever), then reads, decodes and
validates. It builds the `Book` only when all of that succeeds, so there's no
partially loaded state to clean up. Failures become a `LoadError`: the problem, plus
the backups that exist with their modification times, so the message tells the
writer what they could restore by hand:

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

## 9. The testing seam: a Swift protocol where Rust would use a trait

```swift
public protocol FileSystem: Sendable {
    /// `nil` when nothing is at `url`. Follows symbolic links.
    func item(at url: URL) throws(FileSystemError) -> FileItem?

    func read(_ file: URL) throws(FileSystemError) -> Data

    /// Replaces `file` so that after a crash it holds either its old contents or `data`,
    /// never a mix, and returns the stamp of the file now holding `data`.
    func writeAtomically(_ data: Data, to file: URL) throws(FileSystemError) -> FileStamp

    /// Renames `source` to `destination` in one step, replacing anything already there.
    func move(_ source: URL, over destination: URL) throws(FileSystemError)

    /// Creates one directory; its parent must exist. Throws `.alreadyExists` if anything is at `url`.
    func createDirectory(at url: URL) throws(FileSystemError)
}
```

Five operations: exactly what create, open and save use. There's no `remove` or
directory listing, because nothing in the pipeline needs them.

In Rust you'd write `trait FileSystem` and either make `BookPackage<F: FileSystem>`
generic (static dispatch) or store a `Box<dyn FileSystem>`. `BookPackage` stores
`any FileSystem`, the existential that matches `Box<dyn …>`: a dynamically
dispatched box. A generic parameter would leak into every type that holds a
package, the store included, for a few calls per save that cost far less than one
`F_FULLFSYNC`. `Sendable` on the protocol is the `+ Send + Sync` bound: it's what
lets a `BookPackage` cross to whichever executor the store saves on.

The test double, `FaultInjectingFileSystem`, wraps the real `LocalFileSystem` (so
tests run against real temporary directories), records every call, and fails
whichever call it's told to. Its state is behind a `Mutex` from the `Synchronization`
module, the equivalent of `std::sync::Mutex`, which is what lets a `final class` be
`Sendable` without `@unchecked`.

The tests that use it:

- **Every step can fail.** `SaveFault` lists the steps of a save in order, each mapped to
  the call it makes. One test checks that a clean save makes *exactly* those calls in
  that order, so the list can't miss a step; then one parameterized test fails each
  step, twice in a row, and checks that `book.json` is byte-identical, V0–V2 survive,
  and a clean retry ends in the standard layout.
- **Crashes.** The same steps again, but the faulted write leaves a half-written
  temporary file behind, as a real crash would. A fresh `open` on the real file system
  must load V0; after the last step it must load V9.
- **Loading damaged packages.** Truncated, empty, garbage, an invalid book, an
  unsupported format, a missing `book.json`, a directory where `book.json` should be, a
  file where the package should be, a missing package and a missing extension. Each
  must throw the right `LoadProblem`, make no mutating call, and leave the directory
  listing, contents and modification times unchanged.
- **Fuzzing.** 400 seeded random edits of a valid file (byte changes, insertions,
  deletions, truncations): each either loads a book that passes the validator or
  throws a `LoadError`, and never writes. The test asserts that both outcomes
  occurred, so it can't silently degenerate into testing only one.
- **Rotation.** Five saves of distinct content leave `bak1`–`bak3` byte-equal to the
  previous three versions, and an unchanged save leaves the whole package untouched.
