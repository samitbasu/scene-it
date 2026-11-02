# 0024 — A book repaired on open is read-only until the writer confirms

**Status:** Accepted (2026-11-02). Refines [0022](0022-markdown-book-format.md) and [0020](0020-instance-and-book-locks.md).

## Problem
The v2 parser never fails, so a damaged `book.md` (emptied by a sync tool, truncated, binary, the wrong encoding) opens as a
"repaired" book. Autosave would then rewrite it, and after a few saves the original is in no backup: rotation keeps only 3
versions, and snapshots copy only what Scene It wrote.

## Decision
- If parsing `book.md` produces **new** error entries (entries the file didn't already carry in `### Unparsed`), the book opens
  **read-only** with reason `.repairedOnOpen`. A banner explains that Scene It repaired the book while opening it, points to the
  Errors tab, and offers **Make Editable**. Entries already preserved from earlier sessions don't count.
- **Make Editable** first writes the original bytes, unmodified, to a permanent `book.md.original-<UTCStamp>.md` in the package
  (with -2/-3 suffixes on collision; never rotated, pruned or swept), then switches the book to editing. The recovery guide lists
  these files.
- A book whose `format` is newer than this version supports opens read-only with reason `.newerFormat`, and offers no way to make
  it editable (spec §10 Q7).
- How the choice is offered (owner, 2026-11-02): an alert when the book opens (Keep Read-Only is the default), **plus** a persistent banner above the page and File → Make Editable…, so the writer can review and make the book editable later without reopening it. The look goes through the aesthetic gate.

## Not chosen
Keeping the original silently and opening normally (an emptied file would open as an empty book the writer might type into), or
asking only in catastrophic cases.

## Details settled in the implementation (#62)
- **#62 builds the alert** (ADR 0020's read-only alert, with Keep Read-Only as the default and Make Editable). The banner and
  File → Make Editable… are #67; all three call `BookStore.makeEditable()`.
- **The kept bytes are the ones that were parsed**, carried from the open (`Repair`), never a second read of `book.md`. Make
  Editable writes them durably, *then* takes the lock, and the package treats them as what it last read: if `book.md` changed
  after the open, the first save stops with ADR 0018's "changed on disk".
- `.repairedOnOpen` carries one `Repair` (the package, the book and the bytes read), which only `open` can make, and
  `BookPackage.keepOriginal` takes only that, so it can't write one book's bytes into another package. It returns a
  `KeptOriginal`, which can't be copied; `BookPackage.edit` consumes it (handing it back only if the lock can't be had), so
  no code can make a repaired book editable without keeping its original first, or twice from one original.
- An all-digit `format:` too large for an integer, or one written with `+`, is a number (book format §1.5): such a file
  reads as newer, never as damaged, so Make Editable is never offered for it.
- **After Make Editable the repaired book counts as unsaved**, so autosave replaces the damaged file and the notices go into
  `### Unparsed`; the next open finds them already there and opens for editing. Otherwise every open would ask again and
  keep another identical original.
- **A newer format wins over a repair.** Such a file always gets a notice (a new entry), and Make Editable must never be
  offered for it. Neither content reason takes the book's lock.
- If the lock is held elsewhere when the writer chooses Make Editable, the original is still kept and the book stays
  read-only with `.repairedOnOpen`, so it can be tried again.
