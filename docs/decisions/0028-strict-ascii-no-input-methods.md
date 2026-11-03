# 0028 — Strict ASCII text; no input methods on the page

**Status:** Accepted (2026-11-03). **Supersedes the "Characters" section of [0022](0022-markdown-book-format.md)** (Latin-1).
Breaking change while undeployed; the file stays `format: 2`.

## Decision
- **Stored and editable text is printable ASCII** (0x20–0x7E) plus the paragraph structure. `book.md` is therefore pure ASCII, and
  one character = one byte = one UTF-16 unit everywhere.
- **Input methods are disabled on the page and in the notes and title fields** (no input context), so there is no marked text and no
  composition state. Dead keys, press-and-hold accents and IME input aren't available.
- **Anything non-ASCII that arrives** (paste, drop, dictation, autocorrect, text replacement, a hand-edited file) goes through one
  explicit, versioned **transliteration table**: Latin-1 and Windows-1252 letters to their plain forms (é→e, ñ→n, æ→ae, ß→ss,
  ø→o), typographic punctuation to ASCII (“ ”→", ‘ ’→', —→--, –→-, …→...), NBSP to a space. Everything else becomes `[?]`.
  The table is the only place these rules live, and it's not a system transform (which could change between macOS versions).
- **Reading a file:** UTF-8 is decoded and invalid bytes fall back to Windows-1252 as before; then the table applies, plus one
  notice per kind of change (transliterated or replaced).
- **Existing Latin-1 books** (development only) open as repaired, read-only, with the original kept (ADR 0024).

## Why
The owner's call after the #72 review: input-method composition caused a real blocker (text deleted on a scene switch) and
a family of edge cases. ASCII removes that class entirely, and makes every offset and comparison trivial inside the model.

## Cost (accepted)
Accented names can't be written: pasted accents are converted to plain letters (names are altered silently). Typing accents via
Option-key dead keys or press-and-hold doesn't work. Non-Latin text becomes `[?]`.
