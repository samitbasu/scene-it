# 0029 — Review round trip: Export as SceneIt, Review Book, Copy Review

**Status:** Accepted (2026-11-03). A new feature, added to the plan by the owner.

## The flow
1. **Export as SceneIt…** (File menu): the author picks scenes in a chooser listing the manuscript's story scenes with checkboxes
   (all ticked by default; shift-click selects ranges). It writes **one `.md` file** in the book format (ADR 0022, 0028) holding
   those scenes in story order, with **text and inline formatting only**. No comments, notes, tags, colors, highlights or Boneyard.
   The front matter marks it as a review copy, and it keeps the scenes' ids so the review can refer to them. The file can be emailed.
2. **Review Book…** (on the start screen and in the File menu): opens such a `.md` file. The **manuscript text is read-only**, but the
   reviewer can **add comments and notes**. They're **autosaved** with the same safe-save rules (verified atomic write, backups) to a
   **review file beside it**, `<name>.review.md`. The received manuscript is never modified, and reopening it resumes the review.
3. **Copy Review** puts the reviewer's comments and notes on the clipboard as **HTML** (inline styles only, so it pastes formatted
   into Gmail and Mail) **and plain text**. Per scene: its title, then each comment as **☐ the commented passage with a little
   surrounding context, then the comment**, then the reviewer's notes for that scene. It contains no full manuscript text, and no app
   is needed to read it. Typography is smartened (straight quotes become curly, -- becomes a dash).
4. **Save Review…** writes the same content as a **standalone `.html` file** with **real checkboxes** the author can tick in any
   browser (remembered in that browser via localStorage). No external resources and no network.
5. The **author addresses the comments by hand** in their book. There's no automatic import.

## Why these choices
- Text only on export: comments, notes and colors are the author's private working material.
- A review file beside the manuscript: the reviewer's work must survive quitting, crashes and power loss, and stay visible and easy to back up.
- ☐ symbols in email: Gmail strips checkboxes, scripts and forms, so working checkboxes live in the separate `.html` file.

## Open for the spec
The exact review-copy marker, the `.review.md` grammar (comments and notes keyed to scene ids, using range + quote anchors
against the received text), the HTML layout, and the wording. These go to the owner through the usual spec and aesthetic review.
