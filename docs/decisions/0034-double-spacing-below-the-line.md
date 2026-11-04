# 0034 — Double spacing below the line

**Status:** Accepted (2026-11-03, the owner's choice on #95). **Supersedes [0030](0030-text-height-caret.md)** (our own
caret). Deviates from PLAN §6.1, which names `lineHeightMultiple` 2.0 for the body.

## Context
`lineHeightMultiple = 2` makes TextKit 2 lay out every body line twice as tall with the extra space *above* the
letters, so the system's caret and selection, which fill the line, were twice the text's height. ADR 0030 hid the
system caret and drew a text-height one of our own; the owner found it looked wrong, and the selection stayed double
height. The owner chose instead to put the spacing below each line, so that the system draws both at text height.

## Decision
- **The body has `lineSpacing` instead of the multiple**, and the page's text starts that much lower
  (`ManuscriptTextView`'s top inset), so every line keeps the baseline it had. The gap is measured, not written down:
  `ParagraphRole.doubleSpacingGap` is what TextKit adds when it lays a line of the body font out with the multiple
  (28.51 − 14.51 = 14 pt for 12 pt Times New Roman, which is its ascent and descent rounded up to whole points,
  11 + 3; a test pins this).
- **An empty paragraph has its gap as `paragraphSpacingBefore`, and no line spacing.** TextKit lays an empty line out
  with its line spacing inside it (28.51 pt, the letters' slot at its top), which made the caret there double height.
  With the gap before it, the line is 14.51 pt and sits exactly where text typed into it goes.
- **The empty paragraph at the very end** (after a final Return, or an empty scene) has no character to carry a style:
  TextKit lays it out in the typing attributes. It gets the body's indent and no spacing, since the line above has
  its spacing below it.
- One rule, `ParagraphRole.paragraphStyle(for: ParagraphContent)`, decides the style from what the paragraph holds. The
  codec applies it as it renders text, the editor re-applies it to the paragraphs an edit touches
  (`styleParagraphs(of:around:)`), and `SceneTextView` gives the typing attributes the style of the caret's paragraph,
  laying the end line out again when that style changes.
- `CaretIndicator` is gone; the page uses the system's caret and selection.

## Measurements (macOS 27, 12 pt Times New Roman)
| | Before (multiple) | Now |
| --- | --- | --- |
| Baselines, several pages of wrapped, bold, italic and empty paragraphs | — | every one identical (tested) |
| Where the text ends, so the page's height | — | identical (tested) |
| Caret on a text line, a wrapped line, the upstream end of a wrapped line, at 100% and 200% | 28.51 pt | 14.51 pt |
| Caret in an empty paragraph, at the end after Return, in an empty scene | 28.51 pt | 14.51 pt |
| Selection, one line | 28.51 pt | 14.51 pt |
| Selection, each line after the first | 28.51 pt | 28.51 pt, reaching up over the gap |
| Highlight colour (`.backgroundColor`) | ≈ 12 pt | ≈ 12 pt, unchanged |
| Spelling underline | below the baseline | unchanged (drawn from the baseline) |

A selection of two or more lines is therefore still one continuous block, the way TextKit's selection segments join
lines: its first line is text height and every later line reaches up to the one above. A public alternative exists:
hide the system's highlight (`selectedTextAttributes` without a background colour) and draw a rendering-attribute
background on the selected range, which gives a text-height band per line (≈ 12 pt, and not reaching the line's end
at a wrap). It would be ours to keep right (active and inactive colours, every selection change), so this ADR keeps
the system's look; the renders for the owner's choice are on #95.

## Rejected
- **Keeping the multiple with our own caret (ADR 0030).** The owner's verdict: it looked wrong, and the selection
  stayed double height.
- **`lineSpacing` with `paragraphSpacing`, or `paragraphSpacingBefore`, on every paragraph:** each moved every line
  after the first paragraph (by up to 448 pt over the test sample).
- **`minimumLineHeight = maximumLineHeight`:** the lines stay where they were, and so does the double-height caret.
- **An empty paragraph's gap as `paragraphSpacing` (after it):** a text-height caret, but 14 pt above where typed text
  goes.

## Consequences
- The gap below a page's last line is now inside the page instead of above its first line; when pagination arrives
  (print, export), a page break falls after a line's gap, not before its letters.
- An edit that empties a paragraph, or types into an empty one, restyles that paragraph in the same edit; the page
  fuzz's check that the page mirrors the model covers it.
