# 0032 — Commented text gets stacked colored underlines, one per comment

**Status:** Accepted (2026-11-03). Resolves PLAN Q1 (#22).

Commented text is underlined in each comment's color. Where comments overlap, their underlines stack 2 px apart (PLAN §8.1),
drawn by a custom TextKit 2 `NSTextLayoutFragment`. If stacking proves impractical, the fallback is one underline per run in
the newest comment's color.

## Alternatives
- **A light wash behind commented text, plus one underline for the selected comment.** Simpler to draw, but the wash hides
  the writer's own highlight colors.

## Consequences
- Every comment stays visible on the page, overlaps included, and the writer's highlights stay readable.
- The exact underline thickness, spacing and colors are rendered for the owner on the demo text before #24 lands
  (aesthetic call).
- Hit-testing (#24) has to choose among stacked comments: the newest first, and clicking again cycles (PLAN §8.1).
