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
   book open and the app running. Closing the main window (the red button, or Cmd+W, which is Close Book's
   shortcut) does the same.
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
  `install` moves to `open`, and only from `choosing` (`.first`) or for the open book itself (`.replacing`);
  only quitting, or a lost book, moves to `ended`. `open` and `create` outside `choosing` return `.refused`
  without reading anything.
- Within `open`, the book is replaced only by itself read again: Open Anyway (ADR 0020) and ADR 0018's Open
  Other Version. When the original can't be read (`.notAFile`), Open My Version opens the writer's copy in its
  place, as before: it is the same manuscript, and the writer's only version of it.
- If ADR 0018's reopen fails after my version was saved as a copy, the process has no book left. The session
  ends and the app quits (`bookLost`), after the alert naming the copy. The next launch reopens the copy, the
  most recent book.
- Close Book and the close button call `BookController.closeBook()`, which sends `AppRequest.quit`; the app
  answers with `NSApp.terminate`. The test host records the request instead.
- The test host stands in for many launches: `BookController.startOver()` makes a fresh store once a session
  has ended. The app never calls it.

## Wording (drafts, for the owner's pick)
All candidates are in `OneBookWording`; each pick is one line (`closeItem`, `refusal`). Renders:
`OneBookRenders.swift` (see README).
- Menu item: **Close Book** (current) or **Close Book and Quit**.
- Refusal alert, OK only:
  - `cantOpenWhileOpen`: "“Other Book” can't be opened while “My Novel” is open." / "Close “My Novel” first
    (File → Close Book). Scene It will quit; open it again to choose another book."
  - `oneBookAtATime`: "“My Novel” is open." / "Scene It works on one book at a time. To open “Other Book”,
    choose File → Close Book, which quits Scene It, then open “Other Book” again."
  - `closeFirst`: "Close “My Novel” first." / "Choose File → Close Book, then open “Other Book” again."

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
