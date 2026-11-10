# 0040 — A Fix that changes anything the page history edits clears it

**Status:** Accepted (2026-11-08, the owner, on #20 / PR #138). Extends PLAN §8.6 and book format §5.4.

## Decision
An Errors-tab Fix (book format §5.4) that changes anything a scene's page undo history edits clears
that history. The page history edits the scene's body, its comments (ADR 0037) and its tags (#20).
A Fix to the notes clears the notes' history, as before.

`TextPart.historyAgrees` says what each history covers, and `OpenBook.commit`, through which every
Fix and every undo of a Fix goes, asks it. A Fix that changes only the errors list, such as deleting
an entry or editing one it keeps, clears nothing.

Undoing the Fix itself still works: it's on the Errors tab's own history (`errorsUndo`).

## Why
Every step on the page history inverts exactly its own edit, recorded against the scene as the
step left it. A Fix changes the scene from outside that history. A step replayed afterwards would
act on a scene it no longer describes. For the text that already meant clearing (it was the rule
for the body and notes). For tags, inverses that tried to cope with a changed tag list, by looking
for the nearest copy or skipping a spelling already present, each lost or duplicated a tag in some
interleaving. Nothing else in the app writes a scene's tags or comments outside the page history.
Clearing on a Fix makes the interleavings impossible, so the inverses stay exact and simple.

## Consequences
- **Behavior change (approved):** after an Errors-tab Fix to a scene's tags or comments, Undo on
  that scene's page has nothing to undo from before the Fix. This is the same as after a Fix to its
  text.
- Undoing the Fix (Errors tab) changes the scene from outside the page history too, so it clears it
  the same way.
- The tag and comment inverses keep a logged backstop (`Log.store.error`) for a mismatch the rule
  should make unreachable. They take or restore only what still matches, and never guess.

## Alternatives
- **Inverses that adapt** (nearest index, skip a present spelling). Rejected: each patch fixed one
  interleaving and broke another.
- **Clear only for the body** (as before). Rejected: tag and comment steps could then run against a
  scene a Fix had changed.
