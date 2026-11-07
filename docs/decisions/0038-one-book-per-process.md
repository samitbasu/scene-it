# 0038 — One book at a time, never switched in place; Close Book returns to the start screen

**Status:** Accepted (2026-11-06, the owner's decisions on #88; revised 2026-11-07 after the owner's hand test).
Supersedes [0021](0021-one-book-at-a-time.md) on switching books in place; amends
[0020](0020-instance-and-book-locks.md) on books forwarded to the running instance. Wording drafts await the
owner's pick (below).

## Context
#88 was a suspected leak: after a book was closed in a hosted window, its `OpenBook` and editors stayed in
memory. 0021 let a book be replaced in place by another (open, create, or a book forwarded from Finder), which
made the old book's lifetime hard to reason about: it overlapped the new book's, inside one window.

## Decision
1. **One book at a time, and never switched in place.** While a book is open, nothing else opens:
   - File → New Book… and Open Book… are disabled. (Scene It has no Open Recent menu; Recent Books are on the
     start screen.) If a book opens while the New Book panel is up (from Finder, say), the new book isn't
     created, and the writer is told.
   - File → Save is disabled on the start screen, where there's nothing to save.
   - A book forwarded from Finder or `open`, including ADR 0020's hand-off from a second launch, is not
     opened. The window comes forward with an alert saying the open book must be closed first. If the
     forwarded book *is* the open book, the window just comes forward, with no alert.
2. **Close Book returns to the start screen** in the same process. File → Close Book, ⌘W while the book's
   window is key, and the window's red close button all save first, asking when a save can't finish (Retry /
   Cancel / Close Anyway; Cancel keeps the book open), then release the book and show the start screen.
3. **Closing the start screen quits Scene It.** Its red close button quits, through Quit's own path. Whether
   ⌘W does too on the start screen is the owner's open question, a one-line switch
   (`BookController.startScreenCommandW`), currently "quits".
4. **To switch books:** Close Book, then choose on the start screen.

## How it's built
- `BookStore.session` is one enum, `choosing` or `open(OpenBook)`. Only `install` moves to `open`, and the type
  of what it installs says from where: `.chosen(URL)` only from `choosing`; `.again(book)`, the open book's own
  package read again (Open Anyway, ADR 0018's Open Other Version); `.myVersion(copy, replacing: book)`, ADR
  0018's Open My Version, which opens the writer's copy in place of an original that can't be read
  (`.notAFile`): the same manuscript, and the writer's only version of it. Only closing, quitting or a lost
  book moves back to `choosing`. `open` and `create` while a book is open return `.refused` without reading
  anything.
- Only a chosen book that won't load is forgotten from Recent Books. A book read again, or the writer's copy,
  stays there when it won't load. An Open Anyway that can't read the book again leaves the read-only book open
  (`.openedReadOnly`), after telling the writer once, also when it follows Open Other Version.
- While Open Other Version reads the original again, off the main actor, the old book is detached: it isn't
  editable, so the page refuses typing, and an edit that still reaches it is refused rather than lost.
- **A lost book.** If ADR 0018's reopen (the original, or the writer's copy) fails after the writer's version
  was saved as a copy, no book is left open: the start screen shows, the writer is told what happened and
  where their version is (`OneBookWording.bookLost`; the copy is named once), and the copy is first in Recent
  Books.
- **Closing** is `BookStore.closeBook()`, the same leave as quitting (`confirmLeaving`, `settle`) with the close
  wording. The book is detached in the same main-actor turn as the session changes, so it refuses edits from
  then on.
- **Quitting from the start screen** sends `AppRequest.quit`, carried out from a run-loop source
  (`perform(_:with:afterDelay: 0)`), never in the sender's own turn: `terminate` with `.terminateLater` runs a
  nested run loop until the quit path, a main-actor task, replies, and that task couldn't start while the
  sender's job was still running. Nothing is torn down inside a store operation's caller.
- **One close decision.** `BookController.closeAction(from:)` decides what a close does from the state and
  its source (the menu with its key window, or the close button); `perform` carries it out. Today both are
  called when the close's task runs. (Open for the owner: whether a second close that arrives while the first
  is still saving should quit, as it does now, or be ignored.)
- **The Dock icon** brings the main window back if it isn't on screen (`applicationShouldHandleReopen`).
- **⌘W acts on the main window only** while it, or a window it owns (a sheet, a child window, walked up to the
  root), is key. Any other key window (the crash report, say) just closes. The main window is the one whose
  close button `MainWindow` routes; a book forwarded to the running instance brings that same window forward.
- **Release.** A hosted test closes a book in the app's own window and checks that the `OpenBook` and the
  page's editor are released (`BookReleaseTests.swift`). The test host's outermost autorelease pool is never
  drained, so the test looks views up and runs run-loop turns inside pools of its own. The page's `NSTextView`
  outlives the book for a while, held by AppKit (a block `-[NSView _commonAwake]` registers with the
  notification center, and AppKit's `previousKeyViews` table); it no longer reaches the book.

## Wording (drafts, for the owner's pick)
All candidates are in `OneBookWording`; each pick is one line (`startScreenCloseItem`, `refusal`,
`createRefusal`, `bookLost`, `severalBooks`). The menu item is "Close Book". Renders: `OneBookRenders.swift` (see README).
- ⌘W's item on the start screen: **Close Book** (current) or **Close Window and Quit**.
- Refusal alert, OK only:
  - `cantOpenWhileOpen`: "“Other Book” can't be opened while “My Novel” is open." / "Close “My Novel” first
    (File → Close Book), then open “Other Book” again."
  - `oneBookAtATime`: "“My Novel” is open." / "Scene It works on one book at a time. To open “Other Book”,
    choose File → Close Book, then open “Other Book” again."
  - `closeFirst`: "Close “My Novel” first." / "Choose File → Close Book, then open “Other Book” again."
- New book refused (the panel was up when another book opened), OK only:
  - `wasntCreated` (current): "“Untitled” wasn't created, because “My Novel” is open." / "Close “My Novel”
    first (File → Close Book), then choose File → New Book… again."
  - `closeFirst`: "Close “My Novel” first." / "“Untitled” wasn't created. Choose File → Close Book, then choose
    File → New Book… again."
- Lost book, OK only, after the load failure's own text ("Your version was saved as …", the problem, the
  backups):
  - `recentBooksLast` (current): the load failure's title; the message ends "“My Novel (my edits)” is first in
    Recent Books."
  - `closedInTitle`: "Scene It couldn't open “My Novel”, so it closed the book."
- Several books asked for at once on the start screen (the first opens):
  - `addedToRecents` (the wording before this ADR, current): "“A” is open. These books were added to Recent
    Books instead: “B”, “C”."
  - `closeToOpenTheOthers`: "“A” is open. “B” and “C” are in Recent Books: to open one, choose File → Close
    Book, then choose it there."
  - `inRecentBooks`: "Only “A” was opened." / "Scene It opens one book at a time. “B” and “C” are in Recent
    Books."

## Not chosen
- **Close Book quits Scene It (one book per process).** Accepted on 2026-11-06 and implemented, then rejected
  by the owner's hand test: launch reopens the last book, Close Book quit, and New and Open were offered only
  on the start screen, so the start screen could never be reached and there was no way to switch books.
- **Switching books in place** (0021): the old book's lifetime overlapped the new one's in the same window,
  which is where #88's suspected leak lived.
- **Multiple windows, one book each.** The same lifetime questions, multiplied.

## Learning notes
`NSWindow`'s close button is an ordinary `NSButton`, so the app can point its target and action at its own
code (and tell its own window apart by that). AppKit's `terminate` with `.terminateLater` spins a nested run
loop; anything that must happen before the reply has to be able to run from inside that loop, which is why
the quit request is a run-loop source rather than a call. In Rust terms, it's the difference between
`block_on` inside the executor's own task and spawning onto it.
