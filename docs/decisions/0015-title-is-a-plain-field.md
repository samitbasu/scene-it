# 0015 — The scene title is a plain-text field above the page

**Status:** Accepted (2026-11-01). **Deviates from PLAN §6.1** (title as the first paragraph of the page). Supersedes [0014](0014-title-always-bold.md).

## Decision
- **Editor:** the title is edited in its own visible, labelled, single-line text field in the
  editor area *above* the page, not on the page's text surface. The page's `NSTextView` holds
  only the body. PLAN §6.1's title rules (`shouldChangeTextIn` vetoes, the undeletable first
  paragraph, Return jumping to the body) are therefore unnecessary.
- **Plain text:** no formatting and no comments in the title. The formatting bar is inactive
  while the title field has focus.
- **Behaviour:** Return or Tab in the title moves focus to the start of the body. Spellcheck is on.
  Find (Cmd+F) searches the body only. The title has its own undo.
- **Model:** the in-memory title is a plain-text newtype (`SceneTitle`). It encodes to PLAN §5.2's
  shape: `"title": [ { "text": "…" } ]`, or `[]` when empty. Decoding a title that has
  formatting or comment ids keeps the text and drops the attributes, the same normalising-load
  pattern as ADR 0013. Line breaks in a title remain invalid. Pasted line breaks become spaces.
- **Output:** Print and Export to Word still render the title as an 18 pt bold heading at the top
  of the scene, built from data, so it looks exactly as before.

## Why
A separate control removes the most fragile editor code (vetoing edits to keep a locked first
paragraph) and makes "the title is exactly one line" true by construction.

## Consequences
- The JSON format is unchanged; no `format` bump.
- The window gains a visible title field. Its look goes through the aesthetic gate (#13).
- The editor title rules move out of #15. The codec (#14) becomes body-only.
- A comment anchored only in a formatted title loses its anchor on load, so it shows as Detached (PLAN §8.1).
