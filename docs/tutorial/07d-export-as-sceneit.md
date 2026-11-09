# 07d — Export as SceneIt: a projection, a second parser mode, and a save panel

Issue #79 (ADR 0029, review format §2). File → Export as SceneIt… writes one `.md` file holding the
story scenes the writer ticks, with their text and inline styles and nothing else, for a reader to
review. The Swift and macOS lessons: a type whose only constructor enforces what it may hold, one
parser serving two grammars, a verified write to a place the writer picks, and `NSSavePanel` driven
from SwiftUI behind a seam tests can replace.

Files: [`Sources/SceneItCore/Format/ReviewCopyFormat.swift`](../../Sources/SceneItCore/Format/ReviewCopyFormat.swift),
[`Sources/SceneItCore/Format/BookParser.swift`](../../Sources/SceneItCore/Format/BookParser.swift),
[`Sources/SceneItCore/Persistence/ReviewCopyWriter.swift`](../../Sources/SceneItCore/Persistence/ReviewCopyWriter.swift),
[`Sources/SceneItCore/Window/ExportChoice.swift`](../../Sources/SceneItCore/Window/ExportChoice.swift),
[`SceneIt/Window/ExportAsSceneIt.swift`](../../SceneIt/Window/ExportAsSceneIt.swift).

## 1. The only way in is the projection

A review copy must never carry notes, comments, tags, colors or the Boneyard (ADR 0029). Rather
than checking that at the write, `ReviewCopy` makes the leak unrepresentable: its memberwise
initializer is `private`, and the one public way to make a copy is to project a book.

```swift
public init(projecting book: Book, chosen: Set<SceneID>, export: ExportID, exported: Timestamp) {
    let scenes = book.scenes.filter { chosen.contains($0.id) }.map(Self.projected)
    self.init(book: Book(title: book.title, scenes: scenes), export: export, exported: exported)
}
```

`projected` keeps a scene's id, `modified`, title and body, and rebuilds each run with only its
text and styles. Runs that then have the same styles merge (`withMaximalRuns`), which is the form
the parser reads back. In Rust this is a struct with private fields and a single `pub fn` that
builds it, the "parse, don't validate" pattern. Swift's `private init` plays the part of the private
fields: code outside the file can read `copy.book`, but can't make a `ReviewCopy` around a book it
built itself. Filtering `book.scenes` (never the Boneyard's list) also means a Boneyard id in
`chosen` is simply ignored.

`ExportID` is `Identifier<ReviewCopy>`, the same phantom-typed id as `SceneID` and `CommentID`
(chapter 02), so an export id can't be passed where a scene id is wanted.

## 2. One parser, two grammars

The copy is a book file with two more front-matter keys (`export`, `exported`) and one changed
rule: a scene whose id is missing gets `scene-<N>` from its position, not a random ULID, because a
copy is never rewritten and the reviewer's notes key on those ids (review format §2.4). Rather than
fork the parser (CLAUDE.md: a fork *will* drift), the reader takes a `ParseMode`, which says which
front-matter keys it knows, and `finish` takes the fresh-id rule as a closure:

```swift
static func parse(_ bytes: Data, opened: Timestamp, ids: inout some SceneIDSource) -> ParsedBook {
    read(bytes, as: .book).finish(opened: opened) { _, used in fresh(&ids, avoiding: &used) }
}

static func parseReviewCopy(_ bytes: Data, opened: Timestamp) -> (ParsedBook, ReviewCopyFrontMatter) {
    let reader = read(bytes, as: .reviewCopy)
    let book = reader.finish(opened: opened, freshID: positional)
    return (book, reader.reviewCopy)
}
```

The closure's type is `(Int, inout Set<SceneID>) -> SceneID`. It isn't `@escaping`, so it may
capture the caller's `inout ids`: Swift allows that only for non-escaping closures, much as Rust
lets a closure borrow `&mut ids` only while the borrow can't outlive the call. `positional` is a
static function passed by name, like passing `fn` items in Rust.

In book mode the copy's keys stay unknown, so a review copy dropped into a package as `book.md`
opens repaired and read-only, which the corpus case `book/s1.5-review-copy-keys-in-a-book` pins.

## 3. Verified, then atomic, and never in the book

`ReviewCopyFormat.verifiedSerialization` is book format §7.2 for the copy: serialize, parse in
review-copy mode, and refuse unless the parse has no error entries, is the same copy (marker and
scenes), and serializes to the same bytes. `ReviewCopyWriter.write` then follows the book's own
pipeline from chapter 03, through `ChosenFileWrite` (shared with Save Review…): `writeTemporary`
(durable under a hidden name), a read back of that file, then `publish` for a new name or `move`
over an existing file. Before any of it, it refuses a destination inside the open
book's package, comparing canonical paths (`.`, `..` and links resolved, case ignored) and file
identities (`FileSystem.mountedIdentity`, the device and file number from `stat`) of the folders
above it, and refuses anything at the destination that isn't a plain file the writer can write.
Unlike the backups' `FileIdentity`, that identity needs no volume UUID, so it works on network
shares too; it only has to hold while the book is open. The package's identity is the one read as
the book opened (`OpenBook.packageIdentity`), along with the one at its path now: if the writer
renames or moves the package in Finder while it's open, the old path names nothing, but the renamed
folder still has the identity read at open (#157). A package that can't be identified either way
exports nothing, since nothing could tell a destination inside it apart. The store runs it through
`exclusively` and a `@concurrent` hop (chapter 04), and tells the writer through `StorePrompts` when
nothing was written.

## 4. A save panel from SwiftUI, behind a seam

SwiftUI's own `fileExporter` wants a `FileDocument` and writes the file itself, which would skip
the verification. So the app shows AppKit's `NSSavePanel` and keeps the writing:

```swift
static func savePanel(title: String, prompt: String, fileExtension: String) -> SaveDestination {
    SaveDestination { name in
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = prompt
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
```

`runModal()` runs a nested event loop until the writer answers, as `NSAlert.runModal` does
(chapter 04); calling it from a `Task` on the main actor is fine, because the loop keeps the app
responsive while the task waits. New Book… does the same.

`SaveDestination` is a struct holding one closure, a trait object with a single method in Rust
terms. Save Review… ([chapter 07g](07g-copy-and-save-review.md)) uses it too, with its own wording.
The app's `BookController` holds `.exportPanel`; the test host's holds `.nowhere`, which
answers "cancelled" without showing anything, and a hosted test sets `.fixed(url)` to a file in its
own temporary folder. `ExportFlow` asks for the destination each time it needs one (it holds a
`() -> SaveDestination`), so a test can change it after the window exists.

## 5. A sheet, a menu item, and why tests start one step in

The chooser is a sheet whose presence is the model's state: it's up exactly while
`ExportFlow.choice` isn't `nil`.

```swift
private var chooser: Binding<Bool> {
    Binding(get: { export.choice != nil }, set: { if !$0 { export.cancel() } })
}
```

A computed `Binding` is a getter and setter pair; SwiftUI calls the setter if it dismisses the
sheet itself. File a Copy guards its draft against that; a choice of scenes holds nothing worth
guarding, so here dismissal just cancels. Esc goes through the window's one Esc order (chapter 07c):
`EscapeContext.dialog` is now a `DialogStage` (`open` or `busy`), which either dialog can report.
Both dialogs share one frame, `WindowDialog(icon:title:explanation:content:)` in
[`SceneIt/Window/WindowDialog.swift`](../../SceneIt/Window/WindowDialog.swift), and one modifier,
`.windowDialogKeys(keys)`, that hands their Esc to the window's keys: a generic view taking a
`@ViewBuilder` closure, much as a Rust function takes `impl FnOnce() -> impl View`.

The menu item finds the window's flow through `@FocusedValue(\.exportFlow)`, which the window
publishes with `.focusedSceneValue`. SwiftUI only offers the *key* window's values to menus. The
test host never makes its window key (that would pull it in front of whatever the owner is using),
so the hosted tests check that the item is in the File menu and then call `ExportFlow.begin()`,
exactly what the item runs, and follow the real path from there: the window's sheet, the chooser,
Export…, the store, the writer and the file. Esc and Return reach the sheet as key events sent to
it in-process (`press(_:in:)`), the way the window would get them from `NSApplication`.

## 6. Shift-click in a checkbox

SwiftUI's `Toggle` reports only "the user changed me", not how. The modifier keys held during the
click are AppKit's to tell, and `NSEvent.modifierFlags` reads them at the moment the binding's
setter runs, which is inside the click's event handling:

```swift
static func ticked(
    _ scene: SceneID, in flow: ExportFlow, _ choice: ExportChoice,
    modifiers: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
) -> Binding<Bool> {
    Binding(
        get: { choice.isTicked(scene) },
        set: { _ in flow.click(scene, ChoiceClick(modifiers())) })
}
```

The keyboard's state is a default argument, so a test can set the binding as a Shift-click would
without holding Shift down: a seam the size of one closure.

What a click does is a pure function in the core (`ExportChoice.click`): a plain click toggles one
scene and remembers it; a Shift-click sets every scene from the remembered one to this one to
whatever this one becomes, as Mail and Finder do. `ChoiceClick` is a two-case enum rather than a
`Bool` (CLAUDE.md), so the call site says which kind of click it is.
