# 07f — Review Book: a second kind of document without a second app

Issue #80 (ADR 0029, [ADR 0042](../decisions/0042-a-review-is-a-book-in-memory.md), review format
§3–§4). File → Review Book… opens a review copy, the `.md` that Export as SceneIt… writes
([chapter 07d](07d-export-as-sceneit.md)). Its text is read-only; the reviewer comments on it and
keeps notes, and everything autosaves to `<name>.review.md` beside the copy, with the book's
safe-save rules. The Swift and macOS lessons: adding a second document kind as an enum field rather
than a protocol, one gate every mutator asks, pulling a safe-write routine out of a class so two
owners share it, a lock whose release is a `deinit`, and a text view that lets attributes change but
not characters.

Files: [`Sources/SceneItCore/Format/ReviewFormat.swift`](../../Sources/SceneItCore/Format/ReviewFormat.swift),
[`Sources/SceneItCore/Format/ReviewParser.swift`](../../Sources/SceneItCore/Format/ReviewParser.swift),
[`Sources/SceneItCore/Persistence/GuardedWrite.swift`](../../Sources/SceneItCore/Persistence/GuardedWrite.swift),
[`Sources/SceneItCore/Persistence/ReviewFile.swift`](../../Sources/SceneItCore/Persistence/ReviewFile.swift),
[`Sources/SceneItCore/Store/OpenBook.swift`](../../Sources/SceneItCore/Store/OpenBook.swift),
[`Sources/SceneItCore/Store/ReviewWriter.swift`](../../Sources/SceneItCore/Store/ReviewWriter.swift),
[`SceneIt/Editor/KeyboardTextView.swift`](../../SceneIt/Editor/KeyboardTextView.swift).

## 1. A review is a book in memory

Everything a reviewer does, a writer can already do to a book: select text and comment on it, type
notes, delete an error entry, undo. Those features all work on `OpenBook` and its `Book`. So rather
than build an "open review" type and teach the page, the comments panel, the Notes and Errors tabs,
undo and autosave about it, a review *is* a book while it's open:

```swift
public struct Review: Hashable, Sendable {
    public var book: Book
    /// On the review as a whole (review format §3.3). Never carries a comment id: every
    /// assignment takes any off.
    public var notes: [Paragraph] { … }
    /// The export id of the copy this reviews.
    public let copy: ExportID
    public let id: ReviewID
```

`book` holds the copy's story scenes, and each scene's runs carry the reviewer's comment ids exactly
as a book's do. The file format does the translation in both directions: the parser reads the
review file *against the copy* (its comment ranges are offsets into the copy's text) and lays the
comments onto the copy's paragraphs; the serializer writes only the annotations back out. The
in-memory shape is richer than the file, which is the same contract the book format has (CLAUDE.md:
"the JSON format is a contract; the in-memory model may be richer").

The parser reuses the book format's lexical layer, entries and paragraph reader, but it's a reader of
its own (`ReviewReader`), not a mode of `BookParser`: the grammars differ in what a section is (keyed
by id, no body, merged when repeated, an orphan when it names no scene), and a mode flag threaded
through every branch of the book reader would have been harder to read than the hundred lines it
saves. Chapter 07d made the opposite call for the review *copy*, which is a book with two more
front-matter keys. The test for "fork or parameterize" is how many branches the parameter touches.

## 2. One field, one gate

The second document kind is an enum field on the one session class, not a protocol with two
conforming types:

```swift
public enum OpenDocument: Hashable, Sendable {
    case book(PackageLayout)
    case review(ReviewContext)
```

In Rust terms this is `enum Document { Book(PackageLayout), Review(ReviewContext) }` inside the
session struct, rather than `Box<dyn Document>`. The views never become generic, and the few places
that care (filing a copy, the archive, where the files are) `switch` on it, so the compiler lists
every one when a third kind arrives.

What the writer may change is then one question, asked by every mutator:

```swift
    public func accepts(_ edit: EditKind) -> Bool {
        driver(for: edit) != nil
    }

    /// The driver, while `edit` is accepted.
    private func driver(for edit: EditKind) -> AutosaveDriver<C>? {
        guard let driver = editingDriver else { return nil }
        switch (document, edit) {
        case (.review, .manuscript): return nil
        case (.book, _), (.review, .annotations), (.review, .errors): return driver
        }
    }
```

Returning the autosave driver rather than a `Bool` means a method can't change the book and forget
to tell autosave: the only way to get the driver it needs to `send(.edited)` is to pass the gate.
That's the same trick as a Rust function that takes a `&mut Guard` token you can only get from the
lock.

A comment is an edit of the page's runs, so the page's `apply` decides which kind it is from what
changed:

```swift
        let kind = part == .body && Self.changesOnlyComments(from: Array(replaced), to: accepted.paragraphs)
            ? EditKind.annotations : part.editKind
        guard let driver = driver(for: kind) else { return nil }
```

## 3. Sharing a safe write between two owners

`BookPackage.save` was a careful routine: read what's on disk, refuse another program's version unless
the writer chose to keep theirs as a backup, write two temporary files, rotate `bak1…3`, swap the new
file into place with `exchange`, and keep a version that landed during the swap. A review file needs
all of it, but its backups live elsewhere (only the review file sits beside the copy, review format
§9 Q9). Copying it would have been the worst kind of duplication: the trust code, in two places that
must change together.

So the routine moved, unchanged, into a struct parameterized by where the file and its side files are:

```swift
public struct SavedFileLayout: Hashable, Sendable {
    public let file: URL
    public let sideFolder: URL
    /// What the side files are named after: `<sideName>.bak1`, `<sideName>.conflict-<time>`, …
    let sideName: String
```

```swift
struct GuardedWrite {
    let layout: SavedFileLayout
    let fileSystem: any FileSystem

    /// When this throws, the file is unchanged.
    func save(_ data: Data, _ policy: ExternalChangePolicy, _ lastSeen: inout ContentDigest)
        throws(SaveError) -> GuardedWriteOutcome
```

A book's layout is `book.md` with its side files in the package, named `book.md.bak1` and so on, the
names they always had; a review's is `<name>.review.md` with its side files in
`Reviews/<review id>/`. The extraction is behavior-preserving: every existing persistence and store
test passed unchanged after it, before the review's own persistence used it. That's the check that a
refactor really is one (CLAUDE.md, "Testing and verification").

`lastSeen` is `inout`, not stored: each owner keeps the digest of what it last read or wrote under
its own mutex (`Mutex<ContentDigest>` in `BookPackage`, part of `ReviewFile`'s state), and lends it to
the write. Rust would write `&mut ContentDigest`; Swift's `inout` is the same exclusive borrow,
checked by the compiler's exclusivity rules.

## 4. A lock released by `deinit`

The editing lock (ADR 0020) moved too, into a small class:

```swift
final class HeldLock: Sendable {
    private let lock: ExclusiveFileLock
    /// What this lock wrote into its file, where the `flock` alone can't be trusted.
    private let record: LockRecord?
```

`ExclusiveFileLock` is `~Copyable` (chapter 03): exactly one value owns the descriptor, like a Rust
guard. `HeldLock` wraps it in a class because the lock must live as long as whoever holds the
package or review file, and those are shared references; its `deinit` clears our record from the
lock file, and the `ExclusiveFileLock`'s own `deinit` then unlocks and closes. Dropping the last
reference is the release, like `Drop`. One consequence the review opener has to respect: a second
`flock` on the same file from the same process fails while the first is held, so code that locks,
finds the file changed, and wants to start over must let go first:

```swift
            guard let held = lock, (try? fileSystem.read(file)) == data else {
                Log.store.info("a review file changed while it was being locked; reading it again")
                // Released first: the review is opened again as if for the first time.
                lock = nil
```

## 5. A text view whose attributes change but whose characters don't

The page is an `NSTextView`. A comment is an attribute on its text, and adding one goes through the
view (so it's on the page's undo) as an attribute-only change. For a review the view must take those
and refuse typing, deleting, pasting and formatting. `Editability` gains a case:

```swift
enum Editability {
    case editable
    /// The text can't change, but comments on it can: a review's page (ADR 0042).
    case commentsOnly
    case readOnly
```

The view stays `isEditable`, so the selection, the caret and the comment commands work, and its veto
point, `shouldChangeText(inRanges:replacementStrings:)`, lets a change through only if it's the
editor's own change of comments (or the undo or redo of one) and keeps the characters:

```swift
    private func keepsText(_ ranges: [NSRange], _ replacements: [String]?) -> Bool {
        let undo = undoManager
        guard commentChange == .underWay || undo?.isUndoing == true || undo?.isRedoing == true else {
            return false
        }
        guard let replacements else { return true }
```

"Keeps the characters" alone isn't enough: an `NSTextView` offers changes of attributes by itself
(the context menu's Font ▸ Underline, the color panel, Kern), and those ask the veto with `nil`
replacement strings just as a comment does. So the editor marks its own comment change
(`commentChange`, set around `SceneTextEditor.rewrite`), and only that passes. The context menu
drops the items that would change the text, and Find loses Replace. Behind it all, the model's gate
(section 2) refuses anything but a comment; if it ever refuses an edit the view took, the page
reloads from the model. The hosted test sends `underline:` and `changeColor:` to a review's page and
checks the page still mirrors the model, then comments the paragraph.

## 6. Where to read next

- [ADR 0042](../decisions/0042-a-review-is-a-book-in-memory.md) for the decisions and what's not
  done yet (Recent Books, general-notes UI, Comment on Scene).
- [`ReviewFileTests`](../../Tests/SceneItCoreTests/Persistence/ReviewFileTests.swift) for the file
  rules of review format §4 (finding a copy's review by its export id, a second review's name), and
  [`ReviewBookTests`](../../SceneItTests/ReviewBookTests.swift) for the whole path in the app's own
  window.
