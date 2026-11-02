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
- The banner wording goes through the aesthetic gate.

## Not chosen
Keeping the original silently and opening normally (an emptied file would open as an empty book the writer might type into), or
asking only in catastrophic cases.
