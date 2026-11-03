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
Option-key dead keys or press-and-hold doesn't work. Non-Latin text becomes `[?]`. Dictation and the emoji & symbols
palette work through the input system, so on the page and in the title they may be unavailable, and anything they do deliver
goes through the table (an emoji becomes `[?]`). What Option-E itself produces with no input context isn't documented: AppKit's
headers put dead-key state in the text input system (`NSEvent.characters(byApplyingModifiers:)`), and without an input context
`interpretKeyEvents` hands the key to the key bindings, which type the event's `characters` through `insertText` and so through
the policy (a spacing `´` would become `'`). Not observed by hand yet (#74).

## Details settled in the implementation (#74)
- **The table is version 1**, lives in book format §1.2 as the source of truth, and `Transliteration.table` must equal it
  (`TransliterationTableTests` reads the spec). Every Latin-1 and Windows-1252 character beyond ASCII is either in it or
  listed there as deliberately left out (currency signs, superscripts, fractions, °, §, ¶, †, ‰…), which become `[?]`.
- **Decomposed input needs no normalization:** the table removes the eight combining accents that Latin-1 and
  Windows-1252 letters decompose into, so `e` + U+0301 reads as `e`, exactly as `é` does.
- **Transliteration runs per token, after the structure is read** (book format §1.2 step 7): decoding, line endings and
  tabs are file-level, but a character the table changes is spelled in ASCII only inside the text a line yields, so what
  the table writes is always literal text (a bullet's `*` never italicizes, a no-break space is never trimmed and never
  makes a line blank).
- **Typographic punctuation and the no-break space are straightened silently** in a file (the table's `silent` column,
  owner's call on #86), so a book edited in TextEdit opens normally. Every other entry, and every `[?]`, gets a notice,
  and so the book opens read-only as repaired (ADR 0024). Tabs and line endings stay silent. Typing and pasting are never
  noticed.
- **Input methods:** every manuscript editor is a `KeyboardTextView` (`inputContext` is `nil`; `setMarkedText` types its
  plain text instead), so marked text can't arise. Writing Tools is off on them too (`writingToolsBehavior` is always
  `.none`): it rewrites text through paths the veto might not see. The page and the title both veto a change the policy
  would alter and make the admitted one instead, as one undoable change; the page also reloads from the model if any edit
  ever leaves a character the policy doesn't admit. The Errors tab's fix field (a SwiftUI `TextField`) keeps its input method:
  what it holds is admitted when the fix is applied.
