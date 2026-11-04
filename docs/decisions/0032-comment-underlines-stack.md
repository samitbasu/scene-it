# 0032 — Commented text gets stacked colored underlines, one per comment

**Status:** Accepted (2026-11-03). Resolves PLAN Q1 (#22).

Commented text is underlined in each comment's color. Where comments overlap, their underlines stack (PLAN §8.1 says 2 px apart; the exact style is below),
drawn by a custom TextKit 2 `NSTextLayoutFragment`. If stacking proves impractical, the fallback is one underline per run in
the newest comment's color.

## The style (the owner's pick, #24, 2026-11-04)
- **Each line is 1 pt thick, its top 3 pt below the baseline**, clear of the descenders; overlapping comments' lines stack
  downward **1.5 pt apart** (clear space between lines).
- **On the pixels:** a line's thickness and its distance from the line above are each rounded to whole device pixels, and
  every level is counted from the baseline's pixel, so a stack is evenly spaced and every line is crisp:
  | | First line | Line | Line to line |
  | --- | --- | --- | --- |
  | 1x | 3 px below the baseline | 1 px | 3 px (2 px clear) |
  | 2x | 6 px below the baseline | 2 px | 5 px (3 px clear) |
- **Each comment keeps one level across its paragraph**, the lowest no overlapping comment already has, taking comments in
  the order they start (the older first, of two starting together), so a line never jumps as other comments start and end.
- **Stacking limit: 5 on the page at 100%.** The double spacing (ADR 0034) leaves 17.51 pt from the baseline to the next
  line's slot; the deepest line keeps 1 pt clear of it, and half a device pixel spare for the baseline's rounding.
- **Zoom:** the lines are drawn at the real device step (the display's backing scale times the page's zoom, 0.5 to 3), and
  the stack is as deep as fits there, and never deeper than fits at 1x and at 2x at 100%, so it's never more than 5 and
  always stays above the next line's slot and inside the paragraph's drawing surface. At 1x and 50%, for instance, 3 fit.
  **Past the limit, the fallback applies to that stretch only**: one line, at the first level, in the newest covering
  comment's colour.
- **The notes are single-spaced**: no line fits below their letters (2.51 pt of room; a line 3 pt down needs 4). What they
  show instead is the owner's call, rendered as four candidates (#24): a line 3 pt down anyway, into the next line (what
  they show until the pick); a line 1 pt below the baseline, through the descenders; a tint of the comment's colour
  behind the letters; or 2 pt between the notes' lines, which holds one line 3 pt down. Overlapping comments in the notes
  show the fallback in every candidate.
- **A comment in several pieces** keeps one level across its paragraph, from its first piece to its last, so a comment
  between the pieces goes a level down (a known consequence, rendered for the owner).
- A line under a wrapped stretch stops at the line's last letter, not under the space the line breaks at.
- **The selected comment isn't emphasized on the page** (PLAN doesn't ask for it; its card shows the selection, #25).

### How the pick was made
The owner judged two compare sheets. **The first round's sheet (candidates A to E) was invalid:** TextKit keeps a
paragraph's layout fragment when its layout is invalidated, and the fragments then kept the style they were made with, so
some paragraphs drew in another candidate's style. Fragments now read the palette from the delegate every time they draw
(tested: a recolour reaches a fragment already laid out). The second round (A, B and two thinner candidates, F and G, drawn
correctly) chose F over a one-pixel hairline (G) and the earlier 1 pt / 2 pt-apart (A) and 1.5 pt (B) lines.

## Hit-testing (#24)
A plain click on commented text, or on its underlines in the spacing below the line, selects its comment
(`CommentSelection`, shared by the page, the notes and the comments panel): the newest covering comment, or, if one of
them is already selected, the next older one, round again to the newest, so clicking the same spot cycles. The click still
places the caret.
- **Only plain clicks** (the owner's call): a press with Shift, Command, Option or Control, a double click, and a press that
  drags out a selection select no comment.
- A click on text no comment covers leaves the selection as it was.
- A selection belongs to its scene, and goes when the scene no longer has the comment (an undo took it away).
- Each line answers clicks from the top of its letters' slot to the end of the room below it, so a click on an underline
  above the next paragraph's letters is on the underlined letter. The hit-test is TextKit 2's own
  (`NSTextLineFragment.characterIndex(for:)`), never `layoutManager`.

## Redrawing
A change to the comments (a recolour, a comment added or taken away) lays out again only the paragraphs those comments
cover, which redraws them; a paragraph's drawing surface reaches into the spacing below it only if it's commented.

## Alternatives
- **A light wash behind commented text, plus one underline for the selected comment.** Simpler to draw, but the wash hides
  the writer's own highlight colors.

## Consequences
- Every comment stays visible on the page, overlaps included, and the writer's highlights stay readable.
- The exact underline thickness, spacing and colors are rendered for the owner on the demo text before #24 lands
  (aesthetic call).
- Hit-testing (#24) has to choose among stacked comments: the newest first, and clicking again cycles (PLAN §8.1).
