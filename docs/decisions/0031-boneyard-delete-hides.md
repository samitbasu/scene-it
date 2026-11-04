# 0031 — Deleting from the Boneyard hides the scene; nothing is removed from the file

**Status:** Accepted (2026-11-03). Resolves PLAN Q7 (#27).

Permanently deleting a Boneyard scene doesn't remove it from `book.md`. The scene moves to a book-level **Deleted** section
after the Boneyard, and the app no longer shows it anywhere. Deleted scenes are left out of the Boneyard, search, counts,
exports, review copies and printing. There's no Deleted list and no Restore in the app: to bring a scene back, the writer
moves it out of the Deleted section of `book.md` with a text editor. docs/user/recovery.md gains those steps when the feature lands.

## Alternatives
- **Confirmation plus undo for the session** (the PLAN default). Once the session ends, the scene survives only in the
  tiered snapshots, which thin out over time.
- **A Trash period** (e.g. 30 days) before real deletion. Adds a timer, a place to manage and a moment when data is lost.
- **A Deleted list with Restore in the app.** Offered, and declined by the owner: recovery by hand is enough for something
  that should be rare, and it keeps the app's surface small.

## Why
Trust first: no action in the app destroys a writer's words. Because the scene stays in the file, it's also in every
backup, filed copy and external mirror.

## Consequences
- **Book format:** a new book-level heading (proposed: `# Deleted`, after `# Boneyard`, matched like `# Boneyard`). Its
  scenes keep their ids, metadata, notes and comments. The format spec (§1.8 and the heading table) gains it before the
  feature is built, along with corpus cases.
- `book.md` grows with every deletion. Accepted: text is small.
- The delete confirmation's wording should say that the scene stays in the book file. The wording is the owner's call.
- A scene in the Deleted section that a hand edit makes invalid follows the usual tolerant rules (§5).
