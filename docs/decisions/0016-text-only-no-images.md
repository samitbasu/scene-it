# 0016 — Manuscripts are text only; images are refused

**Status:** Accepted (2026-11-01)

The page and notes editors don't accept images (`importsGraphics = false`). Pasting or
dropping mixed content keeps only the text. As a second line of defence, the codec strips
U+FFFC attachment characters, so an invisible placeholder can never reach disk or an export.
Supporting images later would need a file-format change.
