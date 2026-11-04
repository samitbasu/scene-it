# 0030 — A text-height caret on the double-spaced page

**Status:** Accepted (2026-11-03, the owner's choices on #90).

## Context
The body is double spaced with `lineHeightMultiple = 2` (`ParagraphRole.body`). TextKit 2 makes each line fragment
twice the single-spaced height and puts the extra space *above* the glyphs. Since macOS 14 `NSTextView` draws its
caret as an `NSTextInsertionIndicator` subview as tall as the line fragment, so the caret on the page was twice the
height of the text. Measured (Times New Roman 12 pt: ascender 10.69, descender −2.60, leading 0.51):

| | Height | Where |
| --- | --- | --- |
| A single-spaced line (the notes) | 14.51 pt | TextKit rounds ascent and descent up: 11 + 3 + 0.51 |
| A body line fragment | 28.51 pt | 2 × 14 + 0.51; the baseline 25 pt below its top |
| The system caret on the page | 28.51 pt | the whole fragment, 14.3 pt above the ascender |
| The selection highlight | 28.51 pt per line | `_NSTextViewportSelectionLineView`, from the selection segment |
| The highlight color (`.backgroundColor`) | ≈ 12 pt | already the text's height |

## Decision
1. **The text view's own caret is made clear** (`insertionPointColor = .clear`) and the page shows **its own public
   `NSTextInsertionIndicator`**, placed by `CaretIndicator` (owned by `ManuscriptTextView`). Layout, line positions
   and pagination are untouched: no paragraph attribute changes.
2. **The selection highlight stays full line height** (28.5 pt blocks, as in Pages and Word).
3. **The caret is as tall as a single-spaced line of the typing font** (ascent + descent + leading as TextKit lays
   them out: 14.51 pt at 12 pt Times), so it matches the single-spaced notes. It sits on the line's baseline, from
   the selection segment the system caret itself uses (the standard segment of an empty range leaves out a first
   line's indent), so empty paragraphs, the end of the scene and an empty scene get it too. It's a subview of the
   page, so it scales with the zoom.
4. **The notes keep the system caret.** They're single spaced, so it's already this height; `CaretIndicator` stays on
   `ManuscriptTextView` rather than the shared `SceneTextView`, so the clear caret's costs (below) stay on the page.

One policy, in `CaretIndicator`: it shows only for a single empty selection in an editable page that has the
keyboard focus in the key window (the focus as `SceneTextView` records it, which the editor reads too), and moves whenever the text view moves its own caret
(`updateInsertionPointStateAndRestartTimer(_:)`), the viewport finishes a layout pass
(`textViewportLayoutControllerDidLayout(_:)`: TextKit 2 lays out lazily, so a line can move without the selection
moving), the typing attributes change (the editor sets them after the
selection moves), the focus or key state changes, editability changes, or the page is resized. If TextKit lays out
no line to measure, the caret falls back to the font's own metrics and logs it; a failed measurement is never
cached.

## Rejected
- **`lineSpacing` instead of the multiple** (with the text container moved down 14 pt to keep the first line): every
  line with text kept its exact baseline, and the caret on a text line was 14.51 pt. But on an empty paragraph, at
  the end after a paragraph break, and in an empty scene, TextKit gives the empty line the spacing as well, so the
  caret there stayed 28.51 pt; the 14 pt also depends on TextKit's undocumented rounding of the font's metrics.
- **`minimumLineHeight = maximumLineHeight = 28`:** line positions identical to the multiple, and so is the caret
  (28.51 pt).
- **Resizing the text view's own indicator:** it's put back on the next run-loop turn, and also when set from an
  `updateInsertionPointStateAndRestartTimer(_:)` override. Nothing public sizes it.
- **Overriding `drawInsertionPoint(in:color:turnedOn:)`:** never called with TextKit 2 on macOS 26–27.

## Consequences
- **Blinking:** our indicator in `.automatic` mode pauses while typing and blinks again after a pause exactly as the
  system one does (measured side by side).
- **Accessibility:** assistive technologies read the text view's own caret bounds (`accessibilityFrame(for:)`),
  which stay the full 28.5 pt line; Zoom's focus tracking follows the line, which is harmless.
- **Caps Lock and dictation:** the caps-lock badge and dictation's glow attach to the text view's own (clear)
  indicator, so they appear where the full-height system caret is, not beside ours. Dictation is unavailable on the
  page anyway (no input context, ADR 0028).
- **Drag and drop:** the drop caret `NSTextView` shows during a drag takes `insertionPointColor`, so a clear caret
  makes it clear too (measured on a plain `NSTextView`). The page currently refuses text drops altogether
  (`draggingEntered` returns no operation, before and after this change), so nothing is lost today; the drop
  caret needs its color back while a drag is over the page when drops are enabled.
