# 0037 — Comment operations: the page changes the text, the store changes the list

**Status:** Accepted (2026-11-04, the owner's decisions on #23 / PR #118). Deviates from PLAN §8.1 ("The
`BookStore` changes both together") and PLAN §11 (New Comment's shortcut).

## Context
A comment is two things that must agree: its id on the runs it covers, and its entry in the scene's `comments`.
PLAN §8.1 has the store change both together. But the page's undo history records edits against the page's
own text storage, and a body changed from the model (`OpenBook.replaceBody`) clears that history, since it no
longer fits the text. A store method that rewrote the body to add a comment would cost the writer their
typing undo every time they made, dismissed or re-anchored one.

## Decision
- **What changes the page's text goes through the page** (`SceneTextEditor.newComment`, `dismiss`,
  `reanchor`): it rewrites the runs' attributes through the text view, as formatting does, and hands the
  model the edit with the new comment in one call (`OpenBook.apply(_:to:in:adding:)`). The page's undo keeps
  its history.
- **What changes only the list is the store's** (`OpenBook.setText(_:ofComment:in:)`, `recolor`, `dismiss`
  for a detached comment, `removeComments`), each registering its inverse on the page's undo (PLAN §8.6).
- Each writer action is one undo group, ordered so no run ever names a comment the scene doesn't have: a new
  comment registers its removal before the text, and a dismiss takes the text's id off before the entry.
  Each action ends the page's typing coalescing first, so typing after it is a step of its own.
- The pure parts are in core and tested there: what a new comment covers (`commentRanges(selecting:)`),
  where a comment is (`ranges(commentedBy:)`) and the attribute edits (`CommentEdit`).
- **Dismiss removes** the comment (PLAN §8.1: undoing it restores the card and the underline); undo puts the
  entry back at its index.
- **What a new comment covers:** the selection, less ranges of only line breaks (which carry no comment, book
  format §4.2). **A selection of only spaces may be commented** (the owner's call). With no selection, the
  word the caret is in, or the one it follows past closing punctuation ("end.", "dogs'", `"no"`), as a
  double click selects it (so a hyphen splits "well-known"). Nothing to cover beeps and changes nothing.
- **New Comment is Cmd+Shift+M**, not PLAN §11's Cmd+Option+M, which is macOS's Minimize All. It's enabled
  while the page has the focus and can be edited.
- A new comment's color is the last one chosen for a comment (`AppPreferences.lastCommentColor`), **purple**
  at first. The undo names are the owner's: New Comment, Edit Comment, Comment Color, Dismiss Comment,
  Re-anchor Comment.

## Consequences
- A comment operation on the page needs the page's editor; the comments panel (#25) calls the page's
  `SceneTextEditor` for create, dismiss and re-anchor, and either it or `OpenBook` for text and color.
- The store alone can't dismiss a comment that still has text; it refuses rather than leave a run naming a
  missing comment.
