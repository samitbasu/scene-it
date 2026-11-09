# 0046 — In the File Cabinet, a double click opens a filed copy

**Status:** Accepted (2026-11-09, the owner, on #33). Deviates from PLAN §7.4 ("Clicking a card opens
that version of the whole book read-only") and mockup 12's "click one to open it read-only".

## Decision
The File Cabinet's cards follow the Scenes sheet (ADR 0043): a single click selects a card, and a
double click opens that filed copy read-only (§7.5). Clicks on a card's own controls (its tag chips,
+ tag, the note) stay theirs. The sheet's subtitle and the card's tooltip say double-click. The click
policy is shared with the Scenes sheet rather than written again.

## Alternatives
- **A single click opens, as PLAN says.** Faster, but it's a different rule from the Scenes sheet,
  and a stray click near a card's tag fields would swap the whole window into a read-only copy.
