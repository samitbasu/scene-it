# 0041 — Undoing a new scene keeps its words in the Deleted section

**Status:** Proposed (2026-11-08, a default decision on #28, with the coordinator's call on titles; for
the owner's review). Extends PLAN §8.6 and [0031](0031-boneyard-delete-hides.md).

## Decision
Adding a scene (the Scenes sheet's + New scene and its dashed tile, #28) is one step on
`structureUndo`, named "New Scene". Undoing it takes the scene out of the story and reopens the
scene that was open before, if there was one and it's still there. Redo puts the scene back in its
place and opens it.

What happens to the scene taken out depends on what it holds:
- **Nothing but perhaps a title** (no text, notes, comments, tags or error entries,
  `BookScene.isBlankButForItsTitle`): it's gone from the book. Redo brings back the same scene,
  title and all, during the session. A title alone counts as blank because outlining in the sheet
  makes many such scenes, and an undone outline step shouldn't leave anything in the file.
- **Anything more:** it goes to the top of the book's Deleted section (ADR 0031), which the file
  keeps. Redo moves it back out.

**There is no in-app view of the Deleted section yet.** A scene that goes there can be brought back
only by Redo during the session, or by hand in `book.md` with a text editor, as ADR 0031 describes.

## Why
Trust first: no action in the app destroys a writer's words (ADR 0031's reason). While the Scenes
sheet is open, ⌘Z goes to the structure (PLAN §8.6). A writer who added a scene, wrote in it, then
pressed ⌘Z in the sheet to undo something else would otherwise lose that scene's text for good once
the session ended without a Redo. The Deleted section is where the app already puts a scene it hides
without destroying it, so no new place or format is needed. The move uses the same `Book` functions
as deleting from the Boneyard (`delete(_:from:)`, `undelete(_:to:at:)`), so the rule lives once.

## Alternatives
- **Remove the scene outright, always.** Simplest, and what most apps do, but a single ⌘Z could then
  take away a whole scene's text, kept only in the session's redo and the tiered snapshots.
- **Always move it to the Deleted section.** One rule instead of two, but every undone outline step
  would leave a scene in `book.md`.
- **Count a title as words too.** Safer for titles, but outlining and undoing would fill the Deleted
  section with one-line scenes.
- **Refuse to undo an add once the scene holds text.** Safe, but leaves a step on the stack that does
  nothing, which reads as a broken Undo.

## Consequences
- `book.md` can gain scenes in its Deleted section from an undone add, recovered by hand as ADR 0031
  describes.
- The page's and notes' histories of the scene are kept, so after a Redo they still fit it.
