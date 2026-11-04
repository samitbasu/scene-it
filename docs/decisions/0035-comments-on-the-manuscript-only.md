# 0035 — Comments are on the manuscript only

**Status:** Accepted (2026-11-04, the owner's ruling on #24: "You can't comment on a Note. Only on the manuscript.").
Narrows [0017](0017-paste-carries-comments.md) to the page; deviates from PLAN §8.6 ("comments can cover notes text
too").

## Decision
- A comment covers page (body) text only. The notes never draw underlines, and a click in the notes selects no comment.
- **Pasting into the notes keeps the text and its formatting and drops the comments.** ADR 0017's "paste
  carries comments" applies to the page alone: page text copied into the notes arrives without comment ids, and no
  comment is added to the scene. Cut from the page and pasted into the notes, a comment is left detached (its card
  stays), and copied back to the page that text is plain.
- **The model enforces it:** a scene's notes never carry a comment id. `BookScene.notes` takes any off on every
  assignment, and an edit of the notes adds no comment (`OpenBook.apply(_:to:in:adding:)`).

## Notes-anchored comments in `book.md` (#112)
The owner chose a repair. A comment's range in the notes, read from `book.md`, is taken off the comment, which keeps its
body ranges or, with none, is kept detached; a notice names the comment and quotes the text, so the book opens as
repaired (ADR 0024) with the original kept. Marks keep their notes ranges. The serializer never writes a comment's
notes range, and book format §4.2 drops `notes` from a comment's range grammar; in an Unparsed entry or a repair it's
E11. Before #112, the model kept the ids the notes opened with, so a file's notes comment survived edits; now none gets
in, so that rule is gone.

**Why the notes' runs still have a comment field:** the notes and the body are the same `[Paragraph]` everywhere a scene's
text is handled (the codec, `BodyChange`, the editors, `TextPart`'s key paths), so a separate run type for the notes would
fork all of them. The invariant is kept instead where the notes are stored (`BookScene.notes`), so nothing can hold one.

## Consequences
- The notes keep only `TextKit`'s own layout; the comment underliner is the page's (`ManuscriptTextView`).
- Typing attributes never carried comments (PLAN §8.1), and dropping into the notes is impossible (ADR 0036), so pasting
  is the only way in.
