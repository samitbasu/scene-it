# 0052 — The toolbar's zoom is a pull-down

**Status:** Accepted (2026-11-10, the owner, picking layout C from the toolbar renders; #203).
Deviates from PLAN §4.1's "Zoom: − 100% +".

## Decision
The toolbar's zoom is one pull-down button titled with the zoom ("150%"). It lists the zoom ladder
(`Zoom.steps`, 50% to 300%) with the current step ticked, then Zoom In, Zoom Out and Actual Size.
Those three are the View menu's own items (`ZoomStepButtons`), with the same wording and
enablement; only the View menu's copy carries ⌘=, ⌘- and ⌘0. A zoom within the steps' tolerance
of a step (a pinch that ends near 150%) ticks that step (`Zoom.isAt`). Fit Width stays in the View
menu only.

The rest of the toolbar is grouped the same way: Undo and Redo share one glass capsule, Print and
Export to Word share another, and two fixed spacers part the groups and File a copy….

## Alternatives
Renders in `build/review/toolbar/` (`toolbar-options.png` and `-dark`):
- **A, PLAN's stepper as built:** − 150% + in a `ControlGroup`. On macOS 26 each button drew as
  its own glass circle, so the toolbar read as a row of unrelated controls.
- **B:** the same groups as C, with − 150% + in one capsule. Shows the zoom without a click, but
  takes three slots.
- **D:** C with icon-only Print and Export to Word. Narrower, but the two outputs lose their names.

## Consequences
- Choosing an exact step (say 200% from 100%) takes one choice instead of several clicks; stepping
  by one takes two clicks instead of one. The shortcuts are unchanged.
- Fit Width isn't reachable from the toolbar.
