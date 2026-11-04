# 0035 — Comments are on the manuscript only

**Status:** Accepted (2026-11-04, the owner's ruling on #24: "You can't comment on a Note. Only on the manuscript.").
Narrows [0017](0017-paste-carries-comments.md) to the page; deviates from PLAN §8.6 ("comments can cover notes text
too").

## Decision
- A comment covers page (body) text only. The notes never draw underlines, and a click in the notes selects no comment.
- **Pasting or dropping into the notes keeps the text and its formatting and drops the comments.** ADR 0017's "paste
  carries comments" applies to the page alone: page text copied into the notes arrives without comment ids, and no
  comment is added to the scene. Cut from the page and pasted into the notes, a comment is left detached (its card
  stays), and copied back to the page that text is plain.
- **The model enforces it:** an edit or a replacement of the notes carries no comment id the notes didn't already have,
  and adds no comment (`OpenBook.apply(_:to:in:adding:)`, `replaceNotes(of:with:)`).

## Open: notes-anchored comments in `book.md`
The format (book format §4.2) still allows a comment's range to point into the notes (`notes c<start>-<end>`), and the
parser and serializer handle them in full today: the parser puts the id on the notes' runs, the comment is anchored, and
the next save writes the range back. The app now shows them nowhere (no underline, no click), and an edit of the notes
keeps an id they already carry, so nothing is lost silently, but the rule for such files is the owner's to make (#24).

## Consequences
- The notes keep only `TextKit`'s own layout; the comment underliner is the page's (`ManuscriptTextView`).
- Typing attributes never carried comments (PLAN §8.1), so pasting and dropping were the only ways in.
