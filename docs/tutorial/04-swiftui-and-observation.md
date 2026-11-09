# 04 — SwiftUI, Observation and the `BookStore`

Chapters 03 and 03a built the trust components one at a time: a package that saves safely,
backups, locks, and an autosave scheduler. This chapter wires them together behind one object,
the `BookStore`, and connects it to the app: the window, the menus, the alerts and quitting.
It covers `@Observable` (and why it isn't Rust's usual answer to shared mutable state),
`@MainActor` across a whole object graph, `@concurrent` work off the main actor,
`NSApplicationDelegateAdaptor`, `.commands`, and calling AppKit's `NSAlert` from async code.

The window ([`SceneIt/Window/`](../../SceneIt/Window/), #13) has PLAN §4's skeleton: toolbar,
rail, page, right panel and status bar, with the rail's sheets over the page (the Scenes sheet,
#28, is [chapter 07e](07e-the-scenes-sheet.md)'s subject). The page itself is an AppKit text view, the subject of
[chapter 05](05-appkit-interop-textkit2.md).

## Where the code is

| File | What it holds |
| --- | --- |
| [`Store/BookStore.swift`](../../Sources/SceneItCore/Store/BookStore.swift) | one book at a time (ADR 0038): open, create, refuse another, close, quit, ADR 0018's two choices |
| [`Store/OpenBook.swift`](../../Sources/SceneItCore/Store/OpenBook.swift) | the open book: the `Book` value, edits, the autosave driver, the status |
| [`Store/BookWriter.swift`](../../Sources/SceneItCore/Store/BookWriter.swift) | the package and backup keeper, used only off the main actor |
| [`Store/BookStatus.swift`](../../Sources/SceneItCore/Store/BookStatus.swift) | the status bar's one enum, as a pure function of autosave and backups |
| [`Store/StorePrompts.swift`](../../Sources/SceneItCore/Store/StorePrompts.swift) | how the store asks the writer; what it remembers between launches |
| [`Store/StoreWording.swift`](../../Sources/SceneItCore/Store/StoreWording.swift) | every new on-screen string, for the owner's review |
| [`SceneIt/Books/`](../../SceneIt/Books/) | the app side: `BookController` (panels), `BookCommands` (menus), `AlertPrompts` (`NSAlert`) |
| [`SceneIt/AppDelegate.swift`](../../SceneIt/AppDelegate.swift) | launch, books from Finder, deactivation, quitting |

The store lives in `SceneItCore`, which has no AppKit, so all of its behaviour is tested with
`swift test` ([`Tests/SceneItCoreTests/Store/`](../../Tests/SceneItCoreTests/Store/)). The app
layer is thin, and its integration tests drive the real app
([`SceneItTests/BookStoreIntegrationTests.swift`](../../SceneItTests/BookStoreIntegrationTests.swift)).

---

## 1. `@Observable`: shared mutable state, tracked by reads

In Rust, a GUI's model is usually owned by one place and changed through messages (Elm-style),
or shared as `Rc<RefCell<Model>>` with someone remembering to repaint. SwiftUI takes a third
route. A class marked `@Observable` records **which properties each view's `body` read**, and
re-runs exactly those bodies when one of those properties changes:

```swift
@MainActor
@Observable
public final class BookStore<C: Clock<Duration>> {
    public private(set) var current: OpenBook<C>?
    public private(set) var recentBooks: [URL]

    @ObservationIgnored private let clock: C
```

`@Observable` is a macro. It rewrites each stored `var` into a computed property whose getter
calls `access(keyPath:)` and whose setter calls `withMutation(keyPath:)` on a hidden
registrar. While SwiftUI evaluates a `body`, it collects those accesses; a later mutation of
one of them invalidates the view. There is no `objectWillChange`, no `@Published`, and nothing
to forget: a view that never reads `recentBooks` never redraws when it changes.

`@ObservationIgnored` opts a property out. The store's dependencies (the clock, the file
system, the prompts) never change, and tracking them would be noise.

The scaffold window shows the effect. It reads `books.store.current`, so opening or closing a
book swaps the view, and nothing else does:

```swift
            if let book = books.store.current {
                TemporaryBookView(book: book)
            } else {
                TemporaryStartView(books: books)
            }
```

Observation also tracks *through* objects. The status line reads `book.status`, a computed
property on `OpenBook`:

```swift
    public var status: BookStatus {
        switch access {
        case .writable(let driver, _, _): BookStatus(autosave: driver.state, lastBackups: lastSave?.backups)
        case .readOnly(let reason): .readOnly(reason)
        case .closed: .closed
```

Computing it reads `access` and `lastSave` on `OpenBook`, and `state` on the
`AutosaveDriver`, which is `@Observable` too (chapter 03a §4). So a save finishing on the
driver redraws the status line, though the view never mentions the driver.

**Where the Rust analogy breaks.** This is shared mutable state, which Rust makes you
justify. Swift makes it safe a different way: every one of these objects is `@MainActor`
(§2), so all reads and writes happen on one thread, and the compiler rejects any that
aren't. It's closer to a single-threaded `Rc<RefCell<_>>` whose borrow rules are checked at
compile time by actor isolation instead of at run time.

### Views never mutate the model

SwiftUI makes two-way bindings easy (`$model.text`), which would let a text field write into
the `Book` directly. The store forbids that: `book` is `public private(set)`, and every change
goes through a method that also tells autosave, **in the same main-actor turn**:

```swift
        guard let driver = editingDriver, let (list, index) = place(of: id) else { return }
        var scene = book[keyPath: list][index]
        change(&scene)
        guard scene != book[keyPath: list][index] else { return }
        scene.modified = Timestamp(.now, in: .current)
        let bodyChanged = scene.body != book[keyPath: list][index].body
        book[keyPath: list][index] = scene
        if bodyChanged { wordCounts.recount(scene) }
        driver.send(.edited)
```

An edit that changes nothing is not an edit, so a text field re-setting the same value
doesn't schedule a save. A read-only book has no driver, so `edit` returns at its first
line: there's nothing to save it with (ADR 0020, and §4 below).

The scene's title field (ADR 0015) calls the store from its delegate as the writer types, and
the page does the same through `OpenBook.apply` ([chapter 05](05-appkit-interop-textkit2.md)):

```swift
            let title = SceneTitle(pasted: typed)
            book.setTitle(of: scene, to: title)
```

## 2. `@MainActor` on a whole object graph, and `@concurrent` off it

`BookStore`, `OpenBook` and `AutosaveDriver` are all `@MainActor`
([ADR 0011](../decisions/0011-mainactor-default-isolation.md); `SceneItCore` says so
explicitly). That's what makes chapter 03a's rule work: "send `.edited` in the same turn as
the change" is only meaningful if the change and the scheduler share one executor.

The disk work must not run there. A save flushes files to the drive, and when a snapshot is
due it takes about 60 ms (chapter 03 §11). So the package and the backup keeper live in a
`BookWriter`, which is `Sendable` and does everything in `@concurrent` methods:

```swift
    @concurrent
    func save(_ book: Book, onExternalChange policy: ExternalChangePolicy) async throws(SaveError)
        -> WriteResult
    {
        try held.withLock { (held) throws(SaveError) -> WriteResult in
            guard let held else { throw .fileSystem(FileSystemError(.write, layout.book, .notFound)) }
            return try Self.write(book, policy, held.package, held.keeper)
        }
    }
```

`@concurrent` says "run this on the global executor, never on the caller's actor". Calling it
from the main actor is an `await`: the main actor is free while the save runs, and the call
resumes there afterwards. In Rust terms it's `tokio::task::spawn_blocking(...).await`, with the
`Send` checks done by the compiler (`Book` is a value type, `BookPackage` is `Sendable`).

The `Mutex` serializes one book's saves, snapshots and release. The scheduler already never
runs two saves at once; the mutex makes it true of the writer on its own, and gives `release`
something to wait on.

### Capture before you `await`

The saver's job (chapter 03a §4) is to snapshot the book before its first suspension:

```swift
    public func save(_ request: SaveRequest) async throws(SaveError) {
        // Unreachable in practice: closing a book drops its driver, the only caller.
        guard case .writable(_, let writer, _) = access else {
            throw .fileSystem(FileSystemError(.write, layout.book, .notFound))
        }
        let snapshot = book
        do {
            let result = try await writer.save(snapshot, onExternalChange: request.onExternalChange)
```

`let snapshot = book` copies a value type (chapter 00 §2), so typing that lands while the save
is off the main actor changes `self.book`, not the snapshot being written. That edit arrives at
the driver as `.edited` and is saved next.

### Releasing a book off the main actor

Dropping the last reference to a `BookPackage` does I/O: on network volumes it clears its lock
record (ADR 0020). ARC runs `deinit` wherever the last reference is dropped, so "release off
the main actor" means "make sure the last reference dies over there":

```swift
    /// Waits for a running save, then drops the package, which releases the book's lock.
    @concurrent
    func release() async {
        let package = held.withLock { held in
            defer { held = nil }
            return held?.package
        }
        _ = consume package
    }
```

The package is moved out under the lock and dropped by `consume`, on the global executor.
Because the closing code `await`s this, "Open Other Version" can rely on the lock being free
before it reopens the original (§5).

At termination nothing may wait, so `releaseUnlessSaving()` uses `withLockIfAvailable`: if a
save is still running, the kernel drops the `flock` when the process exits anyway.

## 3. One status, one enum

The status bar shows one thing. The tempting model is a set of flags (`isSaving`,
`lastError`, `backupsBroken`, `isReadOnly`), and the status bar picks among them. Instead
`BookStatus` is one enum, computed by a pure function from the autosave state and the last
save's backups:

```swift
    public init<Instant>(autosave state: AutosaveScheduler<Instant>.State, lastBackups: SavedBackups?) {
        switch state {
        case .saving:
            self = .saving
        case .paused(let paused):
            self = .changedOnDisk(paused.error)
        case .unsaved(let unsaved):
            self = unsaved.failure.map { .failed($0.error) } ?? .unsaved
        case .clean:
            if let lastBackups, !lastBackups.areWorking {
                self = .backupsNotWorking(lastBackups)
            } else {
                self = .saved
            }
        }
    }
```

There's no stored status to fall out of date: it's derived each time, and Observation redraws
the line when any input changes. "Backups aren't working" (ADR 0019) appears when everything
is saved but the last save couldn't keep a backup (`BackupStatus.previousVersionNotBackedUp`)
or a snapshot failed. A test feeds it every autosave state and backup outcome.

## 4. The store composes the trust components

Each piece from chapters 03 and 03a has one place where the store uses it:

| Component | Where the store uses it |
| --- | --- |
| `BookPackage.open` / `create` (ch. 03) | `BookStore.load`/`create`, `@concurrent`; a failed load opens nothing and takes no lock |
| `BookPackage.save` + `BackupKeeper.keep` (ch. 03 §11) | `BookWriter.save`, off the main actor, serialized |
| `ExternalChangePolicy` (ch. 03 §7) | passed through from the scheduler's `SaveRequest`; the store keeps no overwrite flag |
| book lock, `OpenedBook.readOnly` (ch. 03 §12) | a read-only book gets no driver and no writer, so it has nothing to save with |
| `AutosaveDriver` (ch. 03a) | one per editable book; `OpenBook` is its weakly held saver |
| `prepareToQuit` / `QuitWording` (ch. 03a §5) | `OpenBook.settle(before:asking:)`, for quitting and for Close Book |

The read-only rule is enforced by shape, not by checks. `OpenBook.access` is

```swift
    private enum Access {
        case writable(AutosaveDriver<C>, BookWriter, Edits)
        case readOnly(ReadOnlyReason)
        case closed
    }
```

so a read-only book has no `BookWriter` to save with. A test opens a book whose lock is
held, tries every edit, Cmd+S, deactivation and quit, and checks that the only write the file
system ever saw was the attempt to take the lock.

`Edits` is `.accepted` or `.refused`. A writable book refuses edits only briefly, during the
last pass of "Open Other Version" (§5), so nothing typed can miss the copy.

### One book at a time, never switched in place (ADR 0038)

A book is chosen on the start screen, and Close Book goes back there; while a book is open,
nothing else opens. New Book… and Open Book… are greyed, and a book Finder or a second launch
sends is refused with an alert. Switching books is "Close Book, then choose".

This came from a suspected leak (#88): closing a book in place could leave the old `OpenBook`
and its editors alive. The older design (ADR 0021) swapped one book for another inside the
window, so their lifetimes overlapped. Now there is always a start screen between two books.
(The first answer to #88 was stricter: one book per *process*, with Close Book quitting. The
owner's hand test found the dead end: launch reopens the last book, so the start screen, the
only place to choose another, was never reachable.)

The store's state is one enum, so "no book", "a book" and "closing it" can't be confused:

```swift
    public enum Session {
        /// The start state, the only one a book can be opened or created from.
        case choosing
        case open(OpenBook<C>)
        /// Close Book is saving the book or asking about it. The book is still open (Cancel
        /// returns to `open`), but another close isn't.
        case closing(OpenBook<C>)
    }
```

`session` is `private(set)`. While Close Book saves or asks, it's `.closing(book)`: the book is
still on screen and Cancel returns to `.open`, but a second close press (decided when it's
pressed, by `BookController.closeAction`) does nothing, so a key repeat can't close the book and
then quit. A book becomes the session's only through `install`, and goes back to `.choosing`
only through leaving (`closeBook` or `prepareToQuit`, which share one
`leave`), `closeForTermination`, or the ADR 0018 path when the other version won't open.
What `install` installs is a `Target` whose case says where it comes from: `.chosen(url)`, only
while `.choosing`; `.again(book)`, the open book's own package read again (Open Anyway, Open
Other Version), so it can't name another path; `.myVersion(copy, replacing: book)`, ADR 0018's
copy in place of an unreadable original. Only a `.chosen` book that won't load is forgotten from
Recent Books.
Asked to open any other book while one is open, the store opens nothing, reads nothing, and
tells the writer why (`OneBookWording.refusal`). Asked for the open book again, it does nothing.
The view and the menus derive from the same enum: `MainWindow` switches on `session`, and New
Book… and Open Book… are enabled only while `isChoosing`.

**Proving the release.** A hosted test closes a book in the app's real window and checks, through
`weak` references, that the `OpenBook` and the page's editor are gone. Two traps made earlier
attempts flaky. The test host's outermost autorelease pool is never drained, so anything
autoreleased in the test's own turns (even the `subviews` arrays a lookup walks) lives forever;
the test does its lookups, and runs its run-loop turns, inside `autoreleasepool {}` of its own.
And the page's `NSTextView` itself outlives the book for a while, held by AppKit (a notification
block registered in `-[NSView _commonAwake]`, and its `previousKeyViews` table), so the test
doesn't assert on it: its editor is `weak`, so it no longer reaches the book. (`leaks
--traceTree=<address> <pid>` on the paused test host is what showed those paths.)

### Doing one thing at a time

Store operations ask questions (alerts), and a question can take minutes. Meanwhile Finder
may hand the app another book, or the writer may quit. Rather than reason about every
interleaving, the store runs its operations one at a time: `exclusively` queues callers on
continuations, first come first served. It's an async mutex, like `tokio::sync::Mutex<()>`,
written in a dozen lines because the store is on one actor and needs no atomics.

## 5. Asking the writer: `StorePrompts` and `NSAlert`

The store never touches AppKit. It asks through a protocol:

```swift
@MainActor
public protocol StorePrompts: AnyObject {
    func ask<Choice>(_ alert: WriterAlert<Choice>) async -> Choice
    func tell(_ notice: Notice) async
}
```

`WriterAlert<Choice>` is a title, a message, and buttons that each carry a typed choice
(`QuitAlertChoice`, `ExternalChangeChoice`, `ReadOnlyChoice`). The tests answer from a script;
the app answers with `NSAlert`:

```swift
    /// The index of the button chosen; with no buttons, AppKit's own OK.
    private static func runAlert(title: String, message: String, buttons: [String]) -> Int {
        let response = alert(title: title, message: message, buttons: buttons).runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
```

(`alert(title:message:buttons:)` builds the `NSAlert`; the renders for the owner's wording
reviews draw that same alert offscreen.)

`runModal()` is synchronous: it runs a nested event loop on the main thread until a button is
pressed. Calling it from an `async` function on the main actor is fine (the main actor *is*
the main thread), and the rest of the app keeps drawing because the nested loop processes
events. The first button is the default (Return), and AppKit maps Escape to a button titled
"Cancel". The alerts are app-modal rather than sheets, because a question can arrive with the
main window minimized or behind another app's (a book forwarded from Finder, say).

### ADR 0018: changed on disk

When a save finds that another program changed `book.md`, the scheduler pauses autosave.
The saver can't call the driver (chapter 03a), so it schedules a task that runs *after* the
driver has handled the failure, and asks only if autosave really is paused:

```swift
            Task { [weak self] in
                guard let self, case .paused = self.autosave?.state else { return }
                await self.store?.askAboutExternalChange(in: self)
            }
```

That ordering holds because the driver reports the failure in the same main-actor job in
which `save` throws; the new `Task` is queued behind it.

- **Keep My Version** sends `.externalChangeResolved`. The next save carries the scheduler's
  approval for exactly the version found, and theirs becomes `bak1`.
- **Open Other Version** saves my in-memory book as a new package next to the original,
  "<Title> (my edits).sceneit" (then "(my edits 2)", …: `BookPackage.create` refusing an
  existing name is the collision check, so there's no race), closes the book, which `await`s
  the release of the original's lock, then reads the original again in its place. Both
  versions survive. If the original can't be read at all (`.notAFile`), the copy is opened
  instead. If the book to open then won't load, no book is left open: the start screen shows
  (ADR 0038), with the copy first in Recent Books.

The copy is written off the main actor, and the writer can keep typing meanwhile. Snapshot
once and close afterwards, and the typing in between is lost. So the store saves the copy,
then compares: if the open book changed during the save, it saves the copy again. The book
is closed in the same main-actor turn as the comparison that finds them equal:

```swift
        var pass = 1
        while true {
            if pass == Self.copyPasses { book.setEdits(.refused) }
            let mine = book.book
            do throws(SaveError) {
                _ = try await copy.save(mine, onExternalChange: .refuse)
            } catch {
                book.setEdits(.accepted)
                await copy.discardCopy()
                await prompts.tell(StoreWording.copyFailed(.save(error)))
                return
            }
            if book.book == mine { break }
            pass += 1
        }
        let writer = book.detach()
```

The loop is bounded: someone who never stops typing would otherwise keep it going forever. For
the last pass the book refuses edits, which disables the editor (`isEditable` is observed),
so that pass is guaranteed to be the final one. A copy that can't be saved is removed rather
than left as an empty "(my edits)" book that looks like the writer's version.

The same care applies to Close Anyway and Quit Anyway. When the writer leaves without saving, a
save may be stuck on a failing disk. The store doesn't `await` that book's release, which waits
for the save: it would hold every later operation, quitting included. Closing starts the release
in the background; quitting releases the lock unless a save is still running
(`releaseUnlessSaving`), and the process exit drops it anyway.

Every path that lets go of a book does it in two steps: `OpenBook.detach()`, which is
synchronous and makes the book refuse edits from then on, then the (asynchronous) release of
the writer it returns. The detach always happens in the same main-actor turn as `session`
changing. A text field's setter can still fire on the old book before SwiftUI redraws, and
an `await` between the two would let that edit land in a book nobody saves.

## 6. The app side

### `NSApplicationDelegateAdaptor`

A SwiftUI app has no `main.swift` and no `NSApplicationDelegate` by default. AppKit events
that SwiftUI doesn't model (files from Finder, quitting, deactivation) still go to a delegate,
which SwiftUI creates for you from a type you name:

```swift
@main
struct SceneItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One window, holding one book at a time (ADR 0038).
    var body: some Scene {
        Window(StoreWording.windowTitle, id: "main") {
            MainWindow(books: .shared)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            BookCommands(books: .shared)
            WindowCommands(books: .shared)
            DiagnosticsCommands(diagnostics: .shared)
        }
    }
}
```

`Window` (rather than `WindowGroup`) is a single window: there's no File → New Window, which
would show the same store twice.

The delegate forwards to the store:

- `application(_:open:)`: books from Finder, from the Open dialog of another app, and from a
  second launch handing off (ADR 0020). Books that arrive before launching finishes are
  collected and opened once it has. Later ones go to `BookController.openForwarded`, which
  brings the window forward and lets the store decide: opened only if the process has no book
  yet, otherwise refused with an alert (nothing at all if it's the open book).
- `applicationDidResignActive`: autosave's `.appDeactivated`.
- `applicationShouldTerminate`: saving is async, but this must answer now. AppKit's answer is
  `.terminateLater`, then `reply(toApplicationShouldTerminate:)` when the decision is made:

```swift
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch phase {
        case .running:
            phase = .quitting
            Task {
                switch await books.store.prepareToQuit() {
                case .left:
                    sender.reply(toApplicationShouldTerminate: true)
                case .stayed:
                    phase = .running
                    sender.reply(toApplicationShouldTerminate: false)
                }
            }
            return .terminateLater
```

`prepareToQuit` asks with `QuitWording`'s alerts until the book is saved or the writer
chooses Quit Anyway or Cancel. Before it returns `true`, it detaches the book in the same
turn as the final synchronous check that nothing is unsaved, then releases the lock.
`applicationWillTerminate` releases anything left, without waiting.

### Closing: the book, then the app (ADR 0038)

File → Close Book (Cmd+W) leads to the store's `closeBook()`, which saves first, asking (Retry /
Cancel / Close Anyway) when it can't, then releases the book; the window stays and shows the start
screen. The window's red close button quits Scene It (#130), through Quit's own path: that saves
first too, asking Quit's questions, and Cancel leaves everything as it was. On the start screen
Cmd+W quits as well, and its menu item reads "Close Window and Quit" there. Each press is decided
when it arrives (`BookController.closeAction`), and while a close or a quit is under way, more
presses do nothing: a double click asks for one quit.
(Replacing SwiftUI's `.saveItem` group removed its own Close, so Cmd+W is ours. From any window
but the main one, Cmd+W just closes that window.) The close button is an `NSButton` whose target
and action `MainWindowCloseButton` points at `press(.closeButton)` once the window exists;
SwiftUI's own window delegate never sees the click, and the routed button is also how the app
tells its main window from any other.

**When** a quit starts matters. With `.terminateLater`, `terminate` doesn't return until the
reply: it spins a nested run loop until `reply(toApplicationShouldTerminate:)`, and returns only
if the reply refuses (the writer's Cancel); a quit that goes through never returns. The reply
comes from a main-actor `Task`, and the main actor is the main queue, which isn't drained while
the job that called `terminate` is still on the stack. Call `terminate` straight from a button's
action or a store operation and the app hangs. So `AppRequests.quit(whenOver:)` schedules it with
`perform(_:with:afterDelay: 0)`: a run-loop source, which fires once the current job has
returned. (A Rust analogy: calling `block_on` from inside the executor's own task.)

`AppRequests` carries requests out through a closure: AppKit in the app, a recorder in the test
host. The deferral is the same code in both, so the hosted tests click the main window's real
close button (twice), check that nothing happened in the click's own turn, then wait for one
`.quit`, recorded with the store idle. Then they run the quit path's own work themselves
(`settleQuit`, what `applicationShouldTerminate` calls) and check the book was saved. That's the
general move for an effect you can't let a test perform: make it a value, and test the value.
(In Rust you'd return an enum from the decision function and keep the side effect in `main`.)

### `.commands`

Menus are declared like views. `CommandGroup(replacing:)` swaps one of SwiftUI's standard
groups for ours:

```swift
        let choosing = books.store.isChoosing
        CommandGroup(replacing: .newItem) {
            Button(StoreWording.newBookMenuItem) { Task { await books.newBook() } }
                .keyboardShortcut("n")
                .disabled(!choosing)
            Button(StoreWording.openBookMenuItem) { Task { await books.openBook() } }
                .keyboardShortcut("o")
                .disabled(!choosing)
        }
```

A menu action is synchronous, so anything async starts a `Task`. In the app target that
`Task` inherits the main actor (ADR 0011), so it can call the store without hopping.
`.disabled` reads `isChoosing`, which Observation tracks like any view input, so the items
grey out the moment a book opens.

### The window's state (#13)

What the window shows over a book is one enum, `WindowMode` (`page`, `scenes`, `search`,
`fileCabinet`), in `SceneItCore` so its transitions are pure and tested with `swift test`. Two
choices keep illegal combinations out:

- **No sheet without a book.** The mode is `@State` inside `BookWindow`, which only exists while
  a book is open, and `MainWindow` gives it `.id(book.instanceID)`. A new identity is a
  new view, so a book read again (Open Anyway, Open Other Version) starts again at the page,
  with new editors. What must survive the rebuild lives on the book, not the view: File a Copy's
  draft is carried to the new `OpenBook`, so its dialog comes back up. It's the SwiftUI spelling of "this
  state is owned by that value".
- **No second copy of "can I edit?".** Read-only is the book's own state (`OpenBook.isEditable`),
  so the window reads it instead of storing it again.

The rail badge, the breadcrumb and the status bar all show where the open scene is. They read
one value, `SceneLocation`, which carries the open scene itself, so they can't disagree.

**Word counts match Microsoft Word** (the owner's decision): a word is a maximal run of
non-whitespace characters, and a run of punctuation alone (`--`, `...`) isn't one. So
"well-known" and "dawn--and" are one word each. Counting is per scene and cached in `OpenBook`
(`SceneWordCounts`): an edit recounts only the scene whose *body* changed, and the book's total
is a sum over the cache. A view body runs on the main actor on every change it observes, so
recounting a 120,000-word book there (about 290 ms) on each keystroke would stall typing. Caching
per scene exploits an invariant: an edit touches one scene. Reordering or cutting scenes needs
no recount at all, because the total sums the counts of whatever scenes the story now holds.

While a sheet is open, the page and panel under it are `.disabled`, and the sheet takes the
keyboard focus (a small `NSViewRepresentable` that makes itself first responder), so keystrokes
and Tab can't reach the hidden editors. A hosted test checks the first responder.

Menus reach the window's state through the **one main window** (ADR 0038): the window over a
book registers its focus-mode chrome and a binding to its mode with `BookController.mainWindowChrome`
as it appears, and `WindowCommands` reads them. They're `nil` with no book open, which disables the
items. SwiftUI's other way, focused values (`.focusedSceneValue` and `@FocusedBinding`), follows the
key window, so the menu would do nothing while another window (the crash report, say) is key; it
also can't be driven by a hosted test, whose windows are never really key. Format and Edit's items
still use focused values for the page, which is about the focused editor.

Toggle Right Panel is greyed out with no book open: `.disabled(books.store.current == nil)`.
SwiftUI refreshes its menu items **lazily**, when AppKit asks a menu to update (the writer
opening it, or a shortcut), not when the store changes. So a test that reads `isEnabled` right
after opening a book sees the old value forever. The hosted test does what opening the menu
does, `menu.delegate?.menuNeedsUpdate?(menu)`, and then looks the item up again, because SwiftUI
may have replaced it.

The right panel's open state and tab are **app preferences**, not book data (ADR 0022):
`AppPreferences`, also `@Observable`, kept in `UserDefaults` for the app and in memory for the
test host and previews (chosen by `ProcessRole`, like `BookMemory`). Toggling the panel never
marks the book unsaved.

### Remembering the last book

The app isn't sandboxed, so the recent-books list is plain paths in `UserDefaults`, behind the
`BookMemory` protocol. At launch the app reopens the most recent book; if it's gone, it's
forgotten silently, and if it no longer loads, the error is shown once and the book is
forgotten, so a damaged book can't make every launch fail. The same memory holds the time of
the last successful save, which the crash alert from chapter 11 now mentions.

The test host and previews get a `TransientBookMemory` and a backup mirror in the temporary
folder, so `scripts/check.sh` never touches the writer's defaults, books or backups. A hosted
test asserts this.

## Trying it

- `swift test --filter BookStoreTests` runs the store's flows against real temporary packages
  (and a fault-injecting file system for failing saves): switching with and without a failing
  save, both ADR 0018 choices, read-only, quitting.
- The hosted tests (`scripts/check.sh`) drive the app's own store: create a book, edit, let
  autosave write `book.md`, reopen it; choose File → Save from the real menu; hand the app a
  book through `application(_:open:)`; write `book.md` from outside and watch the status
  become "Changed on disk".
