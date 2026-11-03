# 0022 — Book format v2: tolerant Markdown

**Status:** Accepted (2026-11-02). **Replaces PLAN §5.2–5.3's JSON format** (`book.json`). Affects ADRs 0013, 0015 and 0016.
Breaking change; no book has shipped, so no migration from v1 JSON is provided.

## Goals
1. **Human-readable and hand-editable** in any text editor.
2. **Robust:** damage is local. A mangled comment line costs that comment, never the document. (A mangled JSON file is useless.)
3. **The parser never fails.** Every byte sequence parses to a book. Anything not understood is kept as an *error entry*, shown in an **Errors** tab, and preserved in the file until the writer clears it.

## The file
The package keeps its layout (ADR 0004), with `book.md` replacing `book.json`. Backups, snapshots and filed copies become `.md`
copies of it. One file holds everything, so moving a scene to the Boneyard is a single atomic write.

```markdown
---
title: My Novel
format: 2
---

## The ferry
id: 01JC4K
modified: 2026-10-31T20:54:00-07:00
tags: opening, Mara

He found the letter under the bench. The tide was **already** turning.

Mara watched from the *rail*.

### Notes
Check the tide tables.

### Comments
- c7 | purple | 2026-10-31T20:40:00-07:00 | c13-19 | "letter" | Too early for this reveal?

### Marks
- color purple | c37-65 | "The tide was already turning"
- highlight green | notes c10-21 | "tide tables"

### Unparsed
(verbatim lines the parser couldn't understand; shown in the Errors tab)

# Boneyard

## The station
id: 01JC9Q
...
```

- **Scenes** are `## ` headings in story order (the heading text is the plain-text title, ADR 0015). The Boneyard's scenes follow
  a `# Boneyard` heading, most recently cut first.
- **Scene metadata** is `key: value` lines directly under the heading (`id`, `modified`, `tags`). An unknown, garbled or missing
  key yields an error entry plus a default (a missing `id` gets a fresh one).
- **Body:** Markdown paragraphs separated by blank lines. Bold, italic and strikethrough are **inline** (`**b**`, `*i*`, `~~s~~`).
  Prose that would read as structure (a line starting `#`, `- `, `---`, or `key:` directly under a heading) is backslash-escaped on
  save, as are literal `*`, `_`, `~` and `\`.
- **Comments** and **Marks** are one entry per line, `|`-separated, each with a **character range** and the **quoted text**:
  - Offsets count characters in the scene's **plain text** (inline markup excluded, paragraphs joined by a single `\n`), from 0.
    A `notes` prefix addresses the scene's notes instead of its body.
  - **No re-anchoring:** if the quote doesn't equal the text at the range, the entry becomes an error entry (kept verbatim).
  - A mark is `color <name>` or `highlight <name>` (palette names from PLAN §6.2). The text color "black" is the absence of a
    color mark (ADR 0013).
- **`### Unparsed`** holds error entries verbatim. Saving writes them back unchanged. They leave only when the writer deletes
  them in the Errors tab, or fixes them so they parse.

## Characters (superseded by [0028](0028-strict-ascii-no-input-methods.md): strict ASCII)
- Allowed: **printable Latin-1** (ASCII plus U+00A0–U+00FF), stored as **UTF-8**. One character is one Latin-1 code point.
- Typographic punctuation is **not stored**: on input, “ ” → `"`, ‘ ’ → `'`, — → `--`, – → `-`, … → `...`. Print and Word
  export "smarten" it back. Searching for `"` therefore finds both opening and closing quotes.
- Any other character (emoji, Greek, CJK, control characters…) becomes the visible placeholder **`[?]`**, on paste and typing, and
  likewise when the parser meets one in a hand-edited file (plus an error entry naming it).
- **Normalization:** input is normalized to NFC before filtering, so a decomposed `e`+U+0301 from another editor becomes `é`
  (U+00E9), not `e[?]`.
- **Encoding tolerance:** bytes that aren't valid UTF-8 are decoded as their Latin-1 characters (an editor that saved Latin-1 or
  Windows-1252 loses nothing) and recorded as one error entry; the next save writes clean UTF-8.
- Offsets count characters (code points), not bytes: `é` is one character but two UTF-8 bytes.

## Saving and verification
`serialize(book) → parse → serialize` must give **identical bytes with zero error entries**, or the save is refused (this
replaces BookCoding's encode-validate step). The parse and serialize pair is the format's executable spec; the precise
grammar lives in [`docs/format/book-format.md`](../format/book-format.md), which is versioned with the code.

## Moved out of the book
`settings` (zoom, voice, rate, right panel, Scenes view) become **app-wide preferences**, stored in UserDefaults (not the book).

## Other files
- **The archive index** (`Archive/index.json`) becomes tolerant text (`Archive/index.md`, one section per filed copy). Filed copies
  are `saveNNNN.md`, exact copies of `book.md`.
- **Backup metadata** (`Backups/book-id`, the mirror's `package.json`) stays as small app-only JSON: it's self-repairing.

## Consequences
The JSON model coding (BookCoding, the strict decoding helpers), BookValidator's role on load, and the fixtures are replaced.
RunCodec stays (attributed string ↔ in-memory runs). The in-memory model gains marks and error entries. Persistence,
backups, snapshots and locks carry over with file-name changes. Search, print and export adapt.
