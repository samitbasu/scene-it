# 0042 — A review is a book in memory; the document decides what changes and where it saves

**Status:** Accepted (2026-11-08, #80), with default decisions taken while the owner was away (listed
in the PR, for the owner's review). Implements Review Book… from [ADR 0029](0029-review-round-trip.md)
and the review format's §3–§4 and §9 Q9 ([`review-format.md`](../format/review-format.md)).

## Context
Review Book… opens a review copy (a `.md` written by Export as SceneIt…), shows its text read-only,
and lets the reviewer comment on it and keep notes, autosaving to `<name>.review.md` beside the copy
with the book's safe-save rules. The page, the comments panel, the Notes and Errors tabs, undo and
autosave all work on an `OpenBook`, which until now could only be a `.sceneit` package. A second,
parallel "open review" type would have forked every one of them.

## Decision
1. **In memory, a review is a book.** `Review.book` is the copy's story scenes in story order, each
   carrying the reviewer's comments on its text (as comment ids on its runs, exactly as a book's),
   the reviewer's notes and the review file's error entries for it; the review's own entries are the
   book's. Beside it: the copy's export id, the review id and the general notes (`ReviewContext`).
   The review parser builds this from the review file and the copy; the serializer writes only the
   annotations (review format §3.9). So the page, the panel, the tabs, undo and autosave are the
   book's own code.
2. **`OpenBook.document`** is `.book(PackageLayout)` or `.review(ReviewContext)`. What the writer may
   change is one question, `OpenBook.accepts(EditKind)`: `.manuscript` (the page's text and styles,
   titles, tags, scenes), `.annotations` (comments and notes) or `.errors`. A review accepts all but
   `.manuscript`. Every edit method asks it, so the model refuses a change to the copy's text whatever
   the view does. A page edit that changes only comment ids (a new comment, a dismissal, their
   undo) counts as `.annotations`. A review's scenes keep the copy's `modified`.
   In the app, the page's `Editability` gains `.commentsOnly`: the view stays selectable and
   commentable, and takes only the editor's own change of comments (and its undo and redo); any
   other change, of characters or of attributes (the system Font menu, the color panel), is refused
   with a beep. Formatting, paste, the context menu's Cut, Paste, Font, Substitutions and
   Transformations, and Find's Replace are off. Should the model still refuse an edit the view took,
   the page reloads from the model and drops its history. The title field reads as a label and the
   Tags tab is read-only; File a Copy… and Export as SceneIt… don't apply. The Errors tab deletes any entry, but fixes only `[comments]` entries: a
   review file has no place for a book's front matter or metadata, and no Errors-tab change may
   alter a scene's text. Repairs, kept originals and Make Editable's two steps are typed per kind
   (`BookRepair`/`ReviewRepair`, `KeptOriginal`/`KeptReviewOriginal`), so a review's can't reach a
   book's code or the other way round.
3. **One safe-save path for both files.** `BookPackage`'s verify → rotate → atomic write (with ADR
   0018's external-change detection and ADR 0019's backup policy) moved, unchanged, into
   `GuardedWrite`, parameterized by a `SavedFileLayout` (the file, and where its side files go). The
   editing lock (`flock` plus the network `LockRecord`) moved into `HeldLock`. `BookPackage` and the
   new `ReviewFile` both use them; `BookPackage`'s behaviour and tests are unchanged, except that a
   lock taken on a path that then fails (a create that can't finish, a book that turns out read-only
   under the lock) now takes its `LockRecord` back out of `.lock` as it's dropped, as a lock released
   normally always did.
4. **Where a review's files go** (review format §9 Q9): only `<name>.review.md` sits beside the copy.
   Its rotated backups (`review.md.bak1…3`), a version another program writes in the instant of a
   save's swap (`review.md.conflict-<time>`), Make Editable's kept originals
   (`review.md.original-<time>.md`) and its lock (`.lock`) are in
   `~/Library/Application Support/Scene It/Reviews/<review id>/`. A review has no tiered snapshots:
   the rotation is its backup. The folder is injected (`ReviewsFolder`), so the test host and tests
   use temporary folders.
5. **The review file is created at the first save that has something to keep** (review format
   §4.1 step 4), under the first free name of `<copy>.review.md`, `<copy>-2.review.md`, …, never
   replacing anything. The review id is made when the review is opened.
6. **The copy is never written.** Nothing holds a writable handle on it; a save verifies the review
   against the copy as it was read, and a review whose text has drifted from the copy reads back
   differently and is refused.
7. **Damaged reviews follow ADR 0024.** New error entries open the review read-only with
   `.repairedOnOpen` (its `Repair` names a `.review` file), taking no lock; Make Editable keeps the
   original in the review's folder, then locks and edits. A review in a newer review format opens
   read-only for good (`.newerReviewFormat`).
8. **Changed on disk (ADR 0018), the coordinator's decision.** When a save finds the review file
   changed by another program, that version's bytes are kept at once beside the review file, under a
   name nothing rotates or replaces, `<name>.review.conflict-<UTC time>.md`, and the alert names it.
   A review can't be kept as a second book, so the alert has one way on, Keep My Version, which saves
   the reviewer's version (the other also goes to `bak1` in the review's folder).
9. **The lock, the coordinator's decision.** A review's lock is a `flock` on a file in Application
   Support, so the reader's folder holds only the review file. A review with a file locks
   `Reviews/<review id>/.lock`. A new review, which has no file yet, locks
   `Reviews/Copies/<export id>.lock`, keyed by its copy, so two new reviews of one copy on this Mac
   can't both be edited; at its first save it takes its own lock before its file appears, then lets
   the copy's go. Application Support is local, so there's no lock record and no Open Anyway.
   **Trade-off for the owner to review:** this lock protects only within one user account on one
   Mac. A review file in a shared or synced folder opened by another user, or on another Mac, isn't
   locked out; ADR 0018's change detection (decision 8) is what keeps both versions then. A lock
   beside the copy would cover those cases at the price of a second file in the reader's folder.

## Not in this change
- Reviews aren't in Recent Books; Review Book… opens them again.
- No UI for the general notes (§3.3) or for Comment on Scene (§9 Q6) yet; general notes read from a
  file are kept and written back unchanged.
- The copy's own error entries (damage in transit, §2.4) aren't listed in the Errors tab yet.
- Stray temporary files a crash leaves beside a review file aren't swept.

## Learning notes
The design is "one type, two capabilities" rather than "two types, one protocol": a Rust analogue is
an `enum Document { Book(PackageLayout), Review(ReviewContext) }` field on the one session struct,
with a single `fn accepts(&self, edit: EditKind) -> bool` every mutator calls, instead of a
`trait Document` with two implementations that the UI would have to be generic over.
