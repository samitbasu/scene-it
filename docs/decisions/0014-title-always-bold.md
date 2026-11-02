# 0014 — The scene title is always bold

**Status:** Accepted (2026-11-01)

## Decision
Bold belongs to the title's Heading 1 style. In the title, the Bold button and Cmd+B are
disabled. Italic, strikethrough, color and highlight still apply. A title run never carries
`bold` on disk: the codec drops it on save, and a file that has it still loads.

## Alternative
Word-style toggling, where bold in a heading makes text regular. The format has no way
to say "not bold", so this would need a `format` bump and a migration.
