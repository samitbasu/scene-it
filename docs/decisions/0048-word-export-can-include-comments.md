# 0048 — Export to Word can include comments

**Status:** Accepted (2026-11-09, the owner's request on #183; the owner chose the checkbox, its wording and the
author on #185; the other defaults below are proposed, pending the owner's review). Amends PLAN §10.2 ("Comments are omitted") and adds to [0047](0047-word-export-writes-its-own-docx.md).
Implemented in #183.

## Context
PLAN §10.2 leaves the comments out of Export to Word. A writer sending a scene to an editor sometimes wants the
opposite: the notes to self as Word comments, in the margin beside the words they're about, for the editor to answer
there. Since 0047 Scene It writes the .docx itself, so it can write Word's comments exactly.

## Decision
- **The save panel has an Include comments checkbox** (the owner's pick of the rendered candidates: the checkbox
  alone, worded "Include comments"), its accessory, off every time the panel opens. It isn't
  remembered: comments are often private, and a remembered tick would send them to the next reader unasked. Unticked,
  the document is byte for byte what it was before this change (a test compares digests).
- **Ticked, each anchored comment becomes a Word comment:** `word/comments.xml` holds its text, and the body wraps the
  text it covers in `w:commentRangeStart` and `w:commentRangeEnd`, followed by a `w:commentReference` run. The part
  has its content-type Override and its relationship from the document (`rId3`), and `styles.xml` gains Word's
  "annotation text" style (`CommentText`: single-spaced, not indented, 10 pt, Word's own size), so the balloons
  aren't double-spaced and indented like the body, and its "annotation reference" character style
  (`CommentReference`, 8 pt), which the reference runs and the balloons' `w:annotationRef` runs take, as Word's do.
  Unticked, neither style is written.
- **Ranges are exact.** With comments, runs are joined only when they're alike in look *and* comments
  (`OutputParagraph.Pieces.sameFormat`), so every comment edge is a run edge. A range starts before the first piece
  its comment covers and ends after the last, in whatever paragraphs those are, so ranges overlap, nest and cross
  paragraph breaks as the scene's comments do. Ranges starting together open longest first, and ranges ending
  together close in the reverse of the order they opened, so ranges sharing an edge nest. A comment whose text is in separate stretches (text inserted inside it later) gets one range from its first
  stretch to its last: one balloon, as print shows one card.
- **Ids and order:** the comments are numbered 0, 1, 2… in the order their text starts, the Comments tab's order
  (`CommentCards`).
- **Detached comments** (their text deleted, PLAN §8.1) are left out: Word has nothing to anchor them to. A scene with
  none anchored still gets an empty `comments.xml` when the box is ticked.
- **Comment text** is smartened as print's comments are (decision 0022), one Word paragraph per line, plain: no
  color, since Word colors comments by author.
- **Author** (the owner's choice): the Mac account's full name (`NSFullUserName()`), with initials from its words'
  first letters; "Scene It" ("SI") when the account has no name. It puts the account's real name in a file sent to
  someone else, as Word does with its own user name.
- **Date:** the comment's creation, as `w:date`, written as the local time the writer's clock showed, without an
  offset, which xsd:dateTime allows. Word is believed to write local time in `w:date` and show it as written, so the
  balloon would show the time the writer saw. **This is unverified until the owner's hand test in Word** (on #183's
  list): the risk is that Word or Pages reads a date without an offset as UTC and shows it shifted by the writer's
  offset (eight hours early in California). If so, the fix is to write the offset (`Timestamp.description`).
- **Smartening:** a `--` or `...` split by a comment's edge stays two hyphens or three dots when comments are
  included, since the two pieces are separate runs smartened apart; without comments it's still a dash. Inside a
  stretch with the same comments it's smartened as before.
- **The XML-character check** covers the comments' text and the author's name: a character XML can't hold refuses the
  export (`WordExportFailure.unwritableCharacter`). The comments' text is admitted by the character policy, so in
  practice only an account name could trip it.
- A filed copy shown over its book exports its own comments, as it exports its own text.

## Alternatives
- **Remember the checkbox** (an app preference, as the panel and zoom are). Saves a click for a writer who always
  exports comments, but a tick left over from one export would leak private notes into the next, sent elsewhere.
- **A separate "Export to Word with Comments…" menu item.** Discoverable without opening the panel, but two items for
  one command.
- **Comments as footnotes, or as bracketed text inline.** Readable anywhere, but not the margin balloons an editor
  answers in, and they change the text.
- **One Word comment per stretch** for a comment in separate stretches. Each stretch exact, but one note shown several
  times.
- **Writing the comment color** (Word has no field for it; it could be a highlight on the anchored text). Word colors
  by author, and a highlight would be mistaken for the writer's own highlighting.
- **The date as UTC with `Z`.** Correct to the letter of xsd:dateTime, but Word would show the UTC time as if it were
  local.

## Learning notes
A WordprocessingML comment has three pieces: the comment itself in `comments.xml` (`w:comment` with an id, author,
initials, date and paragraphs), the range in the document (`w:commentRangeStart` and `w:commentRangeEnd`, which are
siblings of runs, not containers, so ranges can overlap freely and span paragraphs), and the reference mark
(`w:commentReference` in a run after the range's end), where Word attaches the balloon. The `w:annotationRef` run at the
start of the comment's first paragraph is the mark repeated inside the balloon.
