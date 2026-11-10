# 0052 — The toolbar's zoom is a pull-down, and its groups sit at the trailing edge

**Status:** Accepted (2026-11-10, the owner, picking layout R-D3 from the toolbar renders; #203).
Deviates from PLAN §4.1's "Zoom: − 100% +" and its "File a copy…: the prominent button".

## Decision
The breadcrumb stays at the leading edge. A flexible spacer after it puts the controls at the
trailing edge, in three glass capsules parted by two fixed spacers each:

1. **Undo and Redo.**
2. **The zoom:** one pull-down button titled with the zoom ("150%"). It lists the zoom ladder
   (`Zoom.steps`, 50% to 300%) with the current step ticked, then Zoom In, Zoom Out and Actual
   Size. Those three are the View menu's own items (`ZoomStepButtons`), with the same wording and
   enablement; only the View menu's copy carries ⌘=, ⌘- and ⌘0. A zoom within the steps'
   tolerance of a step (a pinch that ends near 150%) ticks that step (`Zoom.isAt`). Fit Width
   stays in the View menu only.
3. **Print, Export to Word and File a copy…**, icon-only, in one plain glass capsule, each with
   its name as a tooltip and accessibility label. Over a filed copy File a copy… is hidden and the
   capsule holds Print and Export to Word.

File a copy… is no longer the blue prominent button, so no toolbar action is visually primary.

## Alternatives
Renders in `build/review/toolbar/` (each with a `-dark` twin):
- **A, PLAN's layout as built** (`A-current.png`): − 150% + in a `ControlGroup`. On macOS 26 each
  button drew as its own glass circle, so the toolbar read as a row of unrelated controls.
- **B** (`B-groups.png`): the groups, with − 150% + in one capsule; three slots for the zoom.
- **C** (`C-groups-zoom-menu.png`): B with the zoom pull-down, labeled Print and Export to Word,
  and the labeled blue File a copy…. The owner's first pick, then changed to R-D3.
- **D** (`D-icon-only.png`): C with icon-only Print and Export to Word.
- **D1–D4**, File a copy…'s look (`file-a-copy-options.png`): labeled blue (`D1-labeled-blue`),
  icon-only blue (`D2-icon-blue`), icon-only plain inside the Print/Export capsule
  (`D3-icon-in-pill`), icon-only plain on its own (`D4-icon-own-pill`).
- **R-variants**, the same right-aligned (`right-justified-options.png`): `R-C`, `R-D1`, `R-D2`,
  `R-D3`, `R-D4`, and `R-C-1016`, `R-D1-1016` at the minimum window width. `.primaryAction`
  placement stays at the leading edge on macOS (`probes/R-C-primary-action-placement.png`), so a
  flexible spacer does the aligning.

## Consequences
- Choosing an exact zoom (say 200% from 100%) takes one choice instead of several clicks;
  stepping by one takes two clicks instead of one. The shortcuts are unchanged.
- Fit Width isn't reachable from the toolbar.
- Print, Export to Word and File a copy… are named only by their tooltips, their accessibility
  labels and the File menu.
