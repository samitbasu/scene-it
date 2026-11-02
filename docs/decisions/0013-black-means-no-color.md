# 0013 — `"color": "black"` loads as "no color"

**Status:** Accepted (2026-11-01). Refines PLAN §5.2 and §6.2.

## Decision
- The in-memory text color has no `black` case; the absence of a color *is* black.
- The decoder **accepts** `"color": "black"` and normalizes it to "no color". The encoder never writes it.
- This is the one deliberate exception to "decoding accepts only what the encoder writes". Such a file loads, and its next save drops the redundant attribute.

## Consequence for the round-trip invariant
The guaranteed invariant is that **our encoder's output is a fixed point** (encode → decode → encode is
byte-identical for anything we wrote). Arbitrary accepted input is not guaranteed to re-encode
byte-identically.

## Alternatives
- **Reject `"black"` outright:** strictest, but unforgiving of hand-edited files.
- **Keep `black` as a real value:** two states that look identical on screen, which is an ambiguous state.
