# 0021 — One book open at a time

**Status:** Accepted (2026-11-02). Settles a question PLAN §3 left open. **Partly superseded by [0038](0038-one-book-per-process.md)** (2026-11-06, revised 2026-11-07): a book is never switched in place. While one is open, opening, creating or receiving another is refused; Close Book saves, closes and returns to the start state, where the next book is chosen.

Scene It has a single main window and one `BookStore`, holding at most one open book.
Opening, creating, or receiving a forwarded book (ADR 0020 handoff) first **saves and closes**
the current one: autosave's save path runs, and if it can't complete, the same choices as quit
apply (Retry / Cancel / proceed-without-saving only by explicit choice). Then the new book opens.
With no book open, the window shows a start state (New Book… / Open Book… / recent books).

The store, autosave driver, backup keeper and book lock each exist once per open book and are
released (off the main actor) when it closes. Multiple windows can be added later if needed.
