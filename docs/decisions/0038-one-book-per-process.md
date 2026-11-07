# 0038 — One book per process; Close Book quits

**Status:** Accepted (2026-11-06, the owner's decisions on #88). Supersedes [0021](0021-one-book-at-a-time.md)
on switching books and on returning to the start state after a close; amends [0020](0020-instance-and-book-locks.md)
on books forwarded to the running instance. Wording drafts await the owner's pick (below).

## Context
#88 was a suspected leak: after a book was closed in a hosted window, its `OpenBook` and editors stayed in
memory. The investigation found no cycle in the app's own code, but couldn't prove there was none in the real
app either (SwiftUI's own retention isn't ours to audit). A long session that switched books could pile up
memory, and a stale editor bound to an old book is a correctness risk, not just a cost.

Rather than chase it, the owner chose to make it impossible: a process holds at most one book for its whole
life. Nothing can outlive a book that is never closed while the process runs.

## Decision
1. **Close Book quits Scene It.** It takes exactly the path Quit takes (`applicationShouldTerminate`), with its
   prompts when a save can't complete: Retry / Cancel / Quit Anyway only by explicit choice. Cancel keeps the
   book open and the app running. Closing the book's window (the red button, or Cmd+W, which is Close Book's
   shortcut while that window is key) does the same.
2. **While a book is open, nothing switches it.**
   - File → New Book… and Open Book… are disabled. (Scene It has no Open Recent menu; Recent Books are in the
     start state only.)
   - A book forwarded from Finder or `open`, including ADR 0020's hand-off from a second launch, is not
     opened. The running app comes forward and shows an alert saying the open book must be closed first. If
     the forwarded book *is* the open book, the window just comes forward, with no alert.
   - To switch books: Close Book (which quits), open Scene It again, choose the book.
3. **The start state** (New Book… / Open Book… / Recent Books) appears only when the app launches with no
   book. Once a book is chosen there, it is this process's book until it quits. An open that fails (damaged,
   locked, cancelled) leaves the start state, as before.

## How it's built
- `BookStore.session` is one enum: `choosing` → `open(OpenBook)` → `ended` (or `choosing` → `ended`). Only
  `install` moves to `open`, and the type of what it installs says from where: `.chosen(URL)` only from
  `choosing`; `.again(book)`, the open book's own package read again (Open Anyway, ADR 0018's Open Other
  Version); `.myVersion(copy, replacing: book)`, ADR 0018's Open My Version, which opens the writer's copy in
  place of an original that can't be read (`.notAFile`): the same manuscript, and the writer's only version of
  it. Only quitting, or a lost book, moves to `ended`. `open` and `create` outside `choosing` return `.refused`
  without reading anything.
- Only a chosen book that won't load is forgotten from Recent Books. A book read again, or the writer's copy,
  stays there when it won't load.
- **A lost book.** If ADR 0018's reopen (the original, or the writer's copy) fails after the writer's version
  was saved as a copy, the process has no book left. The session ends, the writer is told what happened, where
  their version is, and that Scene It will quit (`OneBookWording.bookLost`), and then the app quits. The copy
  stays first in Recent Books, so the next launch reopens it.
- **One quit path.** Close Book and the close button call `BookController.closeBook()`, which sends
  `AppRequest.quit`; the app answers with `NSApp.terminate`, so they ask exactly what Quit asks. The request is
  carried out from a run-loop source (`perform(_:with:afterDelay: 0)`), never in the sender's own turn:
  `terminate` with `.terminateLater` runs a nested run loop until the quit path, a main-actor task, replies,
  and that task couldn't start while the sender's job was still running. For the same reason the store calls
  `bookLost` only after its operation has returned (`isBusy` is false), never inside it. The test host records
  the request where the app would call `terminate`.
- **⌘W is Close Book only in the book's window.** When another window is key (the crash report, say), ⌘W
  closes that window as usual. The book's window is the one whose close button `MainWindow` routes to Close
  Book; a book forwarded to the running instance brings that same window forward.
- **The start state** (open for the owner, a one-line switch, `BookController.startStateClosing`): the close
  button quits; File → Close Book is disabled.
- The test host stands in for many launches: `BookController.startOver()`, compiled only in Debug, makes a
  fresh store once a session has ended. The app never calls it.

## Wording (drafts, for the owner's pick)
All candidates are in `OneBookWording`; each pick is one line (`closeItem`, `refusal`, `bookLost`,
`severalBooks`). Renders: `OneBookRenders.swift` (see README).
- Menu item: **Close Book** (current) or **Close Book and Quit**.
- Refusal alert, OK only:
  - `cantOpenWhileOpen`: "“Other Book” can't be opened while “My Novel” is open." / "Close “My Novel” first
    (File → Close Book). Scene It will quit; open it again to choose another book."
  - `oneBookAtATime`: "“My Novel” is open." / "Scene It works on one book at a time. To open “Other Book”,
    choose File → Close Book, which quits Scene It, then open “Other Book” again."
  - `closeFirst`: "Close “My Novel” first." / "Choose File → Close Book, then open “Other Book” again."
- Lost book, OK only, after the load failure's own text ("Your version was saved as …", the problem, the
  backups):
  - `quitLast`: the load failure's title; the message ends "Scene It will quit now. Open it again to choose a
    book."
  - `quitInTitle`: "Scene It couldn't open “My Novel”, so it will quit."
- Several books asked for at once in the start state (the first opens):
  - `addedToRecents` (the wording before this ADR, current): "“A” is open. These books were added to Recent
    Books instead: “B”, “C”."
  - `closeToOpenTheOthers`: "“A” is open. “B” and “C” are in Recent Books: to open one, choose File → Close
    Book, which quits Scene It, then open it again."
  - `forNextTime`: "Only “A” was opened." / "Scene It opens one book at a time. “B” and “C” are in Recent
    Books for next time."

## Not chosen
- **Find and fix the leak, keep switching in place** (0021). It can't be proven fixed, and any later view that
  retains state would bring it back silently.
- **Multiple windows, one book each, in one process.** The same lifetime problem, multiplied.
- **Closing the window leaves the app running with the book open** (a windowless app with a book locked).

## Learning notes
On macOS one process normally serves every document (AppKit's document model), so "quit to switch" is unusual.
It suits a single-book writing app, and it turns a lifetime question ("is everything that referenced the old
book gone?") into one the kernel answers: a process exit frees everything and drops every `flock` (ADR 0020).
In Rust terms, the book went from an `Rc` that had to be audited for cycles to a value that lives for the
whole of `main`.
