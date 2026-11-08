# 0038 — One book at a time, never switched in place; Close Book returns to the start screen

**Status:** Accepted (2026-11-06, the owner's decisions on #88; revised 2026-11-07 after the owner's hand test;
amended 2026-11-07 by #130: the window's red close button quits).
Supersedes [0021](0021-one-book-at-a-time.md) on switching books in place; amends
[0020](0020-instance-and-book-locks.md) on books forwarded to the running instance. The owner chose the
wording on 2026-11-07 (below).

## Context
#88 was a suspected leak: after a book was closed in a hosted window, its `OpenBook` and editors stayed in
memory. 0021 let a book be replaced in place by another (open, create, or a book forwarded from Finder), which
made the old book's lifetime hard to reason about: it overlapped the new book's, inside one window.

## Decision
1. **One book at a time, and never switched in place.** While a book is open, nothing else opens:
   - File → New Book… and Open Book… are disabled. (Scene It has no Open Recent menu; Recent Books are on the
     start screen.) If New Book is chosen while an open is already running (the launch reopening the last
     book from a slow volume, say, while the start screen shows) and that book opens first, the new book
     isn't created, and the writer is told.
   - File → Save is disabled on the start screen, where there's nothing to save.
   - A book forwarded from Finder or `open`, including ADR 0020's hand-off from a second launch, is not
     opened. The window comes forward with an alert saying the open book must be closed first. If the
     forwarded book *is* the open book, the window just comes forward, with no alert.
2. **Close Book returns to the start screen** in the same process. File → Close Book, and ⌘W while the
   book's window is key, save first, asking when a save can't finish (Retry / Cancel / Close Anyway; Cancel
   keeps the book open), then release the book and show the start screen.
3. **The window's red close button quits Scene It** (#130, the owner, 2026-11-07: "clicking the close (red)
   button on the window _should_ exit the app"), with a book open or on the start screen, through Quit's own
   path: it saves first, asking (Retry / Cancel / Quit Anyway) when a save can't finish, and Cancel keeps the
   book open and Scene It running. On the start screen ⌘W quits too; there the File menu item reads "Close
   Window and Quit" (the owner's pick, 2026-11-07). Until #130 the red button closed the book like Close Book
   did, and quit only from the start screen.
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
- A book stops taking edits the moment it's detached (Close Book, or Open Other Version's reload): the model
  refuses them, and the page, the notes, the title field and the comment cards refuse every change with a
  beep before the view changes (`KeyboardTextView.editability`, #129), so a keystroke between the detach and SwiftUI's next update can't
  appear and then vanish. Tests: the store refuses edits in the reload's gap (a held file read), and the
  page, the title field and a comment card refuse typing on a detached book whose view is still editable.
- **A lost book.** If ADR 0018's reopen (the original, or the writer's copy) fails after the writer's version
  was saved as a copy, no book is left open: the start screen shows, the writer is told what happened and
  where their version is (`OneBookWording.bookLost`; the copy is named once), and the copy is first in Recent
  Books.
- **Closing** is `BookStore.closeBook()`, the same leave as quitting (`confirmLeaving`, `settle`) with the close
  wording. The book is detached in the same main-actor turn as the session changes, so it refuses edits from
  then on.
- **Quitting from the red button or the start screen** asks AppKit to quit from a run-loop source
  (`AppRequests.quit`, `perform(_:with:afterDelay: 0)`), never in the sender's own turn: `terminate` with
  `.terminateLater` runs a nested run loop until the quit path, a main-actor task, replies, and that task
  couldn't start while the sender's job was still running. `applicationShouldTerminate` then runs
  `BookController.settleQuit()` (`prepareToQuit`), which saves first, as Quit does.
- **A close is decided when it's pressed** (the owner's pick, 2026-11-07). `BookController.press(_:)` calls
  `closeAction(from:)` as the menu item's or close button's event arrives, from the state then and the source
  (the menu with its key window, or the close button), and carries it out there: Close Book starts in a task
  (what `press` returns, to wait for), a quit is asked of AppKit as above. ⌘W with a book open closes the
  book; the red button quits (#130); on the start screen both quit.
- **One thing at a time.** While Close Book is saving or asking, the session is `closing(book)` (the book is
  still shown; Cancel returns to `open`). `BookController` also tracks the close and the quit a press (or
  Quit) started, separately, until each ends; each is cleared only by its own owner, so a close's Cancel
  can't end a quit queued behind it. While any of these is under way, a press does nothing: a key repeat, a
  second click, ⌘W during a pending quit, or a press decided while another store operation held the store. A
  quit is over when `settleQuit` ends (it also drops a quit a click had queued but AppKit hadn't started,
  so a Cancel can't be followed by a stray second quit), or, as a backstop, when `terminate` returns without
  the quit path having run. Then the next press is decided afresh. A close stops holding presses once the
  start screen shows, though it goes on releasing the book after that (#129): a press then is a press on the
  start screen, and quits, but the quit is asked of AppKit only once the close has ended, so the store is idle
  when the quit path starts (Quit itself, chosen meanwhile, queues behind the close in the store and ends
  the press's quit). The exception is Close Anyway: its release waits behind a save that may be stuck, so it
  runs on past the close's end, without holding later operations, and a quit can then come first; the lock
  goes when the process ends. Until #129 such a press did nothing, with no beep.
- **File a Copy… and Make Editable…** act on `BookStore.openBook`, which is nil while the book is closing, so
  neither can be started (and then torn down with what was typed) during Close Book's save or questions.
  Whether each can start is decided once, by the store (`fileableBook`, `canMakeEditable`), and the File menu,
  the toolbar's File a copy… (both through `FilingFlow.canBegin(in:)`, which adds that the dialog isn't up)
  and the read-only banner's Make Editable… all ask it (#129).
- **The Dock icon** brings the main window back if it isn't on screen (`applicationShouldHandleReopen`).
- **⌘W acts on the main window only** while it, or a window it owns (a sheet, a child window, walked up to the
  root), is key. Any other key window (the crash report, say) just closes. The main window is the one whose
  close button `MainWindow` routes; a book forwarded to the running instance brings that same window forward.
- **Release.** A hosted test closes a book in the app's own window and checks that the `OpenBook` and the
  page's editor are released (`BookReleaseTests.swift`). The test host's outermost autorelease pool is never
  drained, so the test looks views up and runs run-loop turns inside pools of its own. The page's `NSTextView`
  outlives the book for a while, held by AppKit (a block `-[NSView _commonAwake]` registers with the
  notification center, and AppKit's `previousKeyViews` table); it no longer reaches the book.

## Wording (the owner's picks, 2026-11-07)
All in `OneBookWording`; the alerts have only an OK button. Renders: `OneBookRenders.swift` (see README).
- File menu: **Close Book** with a book open; **Close Window and Quit** on the start screen.
- Another book asked for while one is open: "“Other Book” can't be opened while “My Novel” is open." /
  "Close “My Novel” first (File → Close Book), then open “Other Book” again."
- New Book refused: "“Untitled” wasn't created, because “My Novel” is open." / "Close “My Novel” first
  (File → Close Book), then choose File → New Book… again."
- Lost book: the load failure's own text ("Your version was saved as …", the problem, the backups), ending
  "“My Novel (my edits)” is first in Recent Books."
- Several books asked for at once on the start screen (the first opens): "Scene It opens one book at a time." /
  "“A” is open. “B” and “C” are in Recent Books: to open one, choose File → Close Book, then choose it there."
- Several books asked for at once on the start screen, and none opens (the first can't be read): "Scene It
  opens one book at a time." / "“B” and “C” are in Recent Books: to open one, choose it there." (the owner's
  pick, 2026-11-08, #129).

## Not chosen
- **Other wording:** shorter refusals ("Close “My Novel” first."), a lost-book title saying the book was
  closed, the pre-ADR several-books wording ("added to Recent Books instead", kept for the none-opens case
  until #129), the none-opens notice starting "None of them opened.", "Close Book" on the start screen too,
  and ⌘W doing nothing there.
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
