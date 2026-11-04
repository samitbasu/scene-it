# Scene It book format, version 2 (`book.md`)

**Status:** Draft for the owner's review. Implements [ADR 0022](../decisions/0022-markdown-book-format.md), which is
binding. This document is the precise grammar ADR 0022 refers to, and it's versioned with the code.

The review round trip's files (the exported review copy and `<name>.review.md`, [ADR 0029](../decisions/0029-review-round-trip.md))
reuse this document's rules; they're specified in [review-format.md](review-format.md).

It's written for two readers:

- **A writer** editing `book.md` in a text editor. §1–§5 explain what you can type and what happens if you get it
  wrong. The short answer: *nothing you type can stop the book opening*. Anything Scene It can't understand is kept and
  shown in the **Errors** tab.
- **An engineer** implementing `parse(bytes) → Book` and `serialize(Book) → bytes`. Two independent implementations of
  this document must produce the same bytes from the same book, and the same book from the same bytes.

**Conventions**

- **†** marks a rule this document added (not settled by ADR 0022); all † rules were accepted by the owner (§10). Everything unmarked follows
  ADR 0022 directly, or follows from it with no real choice. §10 collects the proposals that most need a decision.
- `␠` stands for a space (U+0020) where it matters. `⏎` is the end of a line.
- "Character" means one Unicode scalar value. After §1.2's filtering every character is printable ASCII, so a
  character is also exactly one byte, one UTF-16 unit, one Swift `Character` and one grapheme.
- A *logical line* is one or more physical lines joined (§4.1). Unless a rule says otherwise, "line" means a physical
  line after §1.3's trimming.

---

## Contents

1. [The file as a whole](#1-the-file-as-a-whole)
2. [Scenes](#2-scenes)
3. [Paragraphs and inline markup](#3-paragraphs-and-inline-markup)
4. [Comments and marks](#4-comments-and-marks)
5. [Unparsed entries and the Errors tab](#5-unparsed-entries-and-the-errors-tab)
6. [The parser never fails: damage and its result](#6-the-parser-never-fails-damage-and-its-result)
7. [Canonical form and save verification](#7-canonical-form-and-save-verification)
8. [The archive index (`Archive/index.md`)](#8-the-archive-index-archiveindexmd)
9. [Examples](#9-examples)
10. [Open questions for the owner](#10-open-questions-for-the-owner)

---

## 1. The file as a whole

### 1.1 At a glance

```markdown
---
title: My Novel
format: 2
---

## The ferry
id: 01JCM9S346Q3D25VT4F5V37E3S
modified: 2026-11-02T09:00:00-08:00
tags: opening, Mara

The ferry left at dawn, and Mara watched the harbor lights go out one by one behind her.

### Notes
Check the tide tables: would a ferry really leave at dawn in March?

### Comments
- c2 | red | 2026-10-31T20:38:00-07:00 | c0-22 | "The ferry left at dawn" | Check the ferry schedule for the 1950s.

# Boneyard

## The brother's boat
id: 01JCY1JX4WHRDD459GQ8H7QEZZ
modified: 2026-07-09T13:00:00-07:00

Pieter had painted the boat the same blue as the house, which nobody mentioned.
```

In order, the file holds:

| Part | Required? | Written when |
| --- | --- | --- |
| Front matter (§1.5) | Expected; defaults apply if missing | Always |
| Book-level `### Unparsed` (§5) | No | The book has book-level error entries |
| Story scenes, each a `## ` heading (§2) | No | One per scene, in story order |
| `# Boneyard` heading (§1.8) | No | The Boneyard has at least one scene † |
| Boneyard scenes | No | Most recently cut first |

### 1.2 Bytes to characters

The reader turns bytes into text in this exact order. Every step is total: none of them can fail.

| Step | Rule |
| --- | --- |
| 1. Decode | Decode as UTF-8. A *well-formed* sequence is one allowed by the Unicode Standard's Table 3-7 (no overlong forms, no surrogates, nothing above U+10FFFF). Every byte that isn't part of a well-formed sequence is decoded on its own as its **Windows-1252** character †, and the book gets **one** encoding notice (§5.3), however many bytes there were. Windows-1252 equals Latin-1 for bytes 0xA0–0xFF. Bytes 0x80–0x9F give 1252's typographic characters (0x93 → “), which step 7 then spells in ASCII. The five bytes 1252 leaves undefined (0x81, 0x8D, 0x8F, 0x90, 0x9D) decode as the C1 control of the same value, which step 7 replaces. See §10 Q2. |
| 2. Byte-order mark | A U+FEFF at the very start is removed silently †. Anywhere else it's an ordinary disallowed character. |
| 3. Line endings | `\r\n` and lone `\r` become `\n`. |
| 4. Tab | U+0009 becomes a space † (§10 Q3). |
| 5. Record | Allowed characters are **printable ASCII**, U+0020–U+007E, plus `\n` (ADR 0028). Every other character is looked up in the transliteration table below, and its code point is recorded, with what will happen to it (silently spelled in ASCII, spelled with a notice, or replaced), against the physical line it was on (for the notices in §5.3). The character itself stays as it is for now. |
| 6. Split | Split on `\n` into physical lines. If the text ends with `\n`, the empty string after it isn't a line. |
| 7. Transliterate † | Once a line's structure has been read (§1.3 trimming, §1.4 headings, §3's escapes and style delimiters, §4's fields), each piece of **text** it yields (a paragraph's characters in their styles, a title, a tag, a metadata or front matter value, a comment's text and quotes, an entry's payload) has each disallowed character replaced by the table's ASCII (possibly nothing) or, if it isn't in the table, by the three characters `[?]`. Characters are taken one scalar at a time, with no normalization: a decomposed `e` + U+0301 is an `e` and a combining accent, which the table removes, so it reads as `e` just as a precomposed `é` (U+00E9) does. |

Step 7 comes after the structure is read so that what the table writes is always literal text: a bullet `•`
becomes a literal `*`, never an italic delimiter, `˜˜` never strikes through, `\•` is a backslash and a `*`, and a
no-break space is never trimmed, never makes a line blank and never counts as the space after a heading's `#`s.
After it, every character of the book is one ASCII byte, so offsets (§3.6) count bytes and characters alike, and a
comment's quote is compared with the text after both are transliterated.

#### The transliteration table (version 1)

ADR 0028: the one place where text that isn't ASCII is given an ASCII spelling. The editor applies the same table
to typing and pasting; implement it once, as data, and use it in both places. It isn't a system transform
(Unicode normalization, `ICU` transliteration), whose results can change between operating system versions. It
covers Latin-1 (U+00A0–U+00FF), the characters Windows-1252 adds (its bytes 0x80–0x9F), and the combining
accents those letters decompose into. Its version is raised with every change, since the same file can read
differently under two versions. `␠` is a space; *(removed)* means the character becomes nothing; *Notice* is
`silent` or `noticed` (below). Scene It's `Transliteration.table` holds the same entries; a test reads this
section and compares the two.

**Latin-1**

| Code point | Character | Becomes | Notice |
| --- | --- | --- | --- |
| U+00A0 | *no-break space* | ␠ | silent |
| U+00A1 | ¡ | *(removed)* | noticed |
| U+00A6 | ¦ | `\|` | noticed |
| U+00A9 | © | `(c)` | noticed |
| U+00AA | ª | `a` | noticed |
| U+00AB | « | `"` | noticed |
| U+00AD | *soft hyphen* | *(removed)* | noticed |
| U+00AE | ® | `(R)` | noticed |
| U+00B1 | ± | `+/-` | noticed |
| U+00B4 | ´ | `'` | noticed |
| U+00BA | º | `o` | noticed |
| U+00BB | » | `"` | noticed |
| U+00BF | ¿ | *(removed)* | noticed |
| U+00C0 | À | `A` | noticed |
| U+00C1 | Á | `A` | noticed |
| U+00C2 | Â | `A` | noticed |
| U+00C3 | Ã | `A` | noticed |
| U+00C4 | Ä | `A` | noticed |
| U+00C5 | Å | `A` | noticed |
| U+00C6 | Æ | `AE` | noticed |
| U+00C7 | Ç | `C` | noticed |
| U+00C8 | È | `E` | noticed |
| U+00C9 | É | `E` | noticed |
| U+00CA | Ê | `E` | noticed |
| U+00CB | Ë | `E` | noticed |
| U+00CC | Ì | `I` | noticed |
| U+00CD | Í | `I` | noticed |
| U+00CE | Î | `I` | noticed |
| U+00CF | Ï | `I` | noticed |
| U+00D0 | Ð | `D` | noticed |
| U+00D1 | Ñ | `N` | noticed |
| U+00D2 | Ò | `O` | noticed |
| U+00D3 | Ó | `O` | noticed |
| U+00D4 | Ô | `O` | noticed |
| U+00D5 | Õ | `O` | noticed |
| U+00D6 | Ö | `O` | noticed |
| U+00D7 | × | `x` | noticed |
| U+00D8 | Ø | `O` | noticed |
| U+00D9 | Ù | `U` | noticed |
| U+00DA | Ú | `U` | noticed |
| U+00DB | Û | `U` | noticed |
| U+00DC | Ü | `U` | noticed |
| U+00DD | Ý | `Y` | noticed |
| U+00DE | Þ | `TH` | noticed |
| U+00DF | ß | `ss` | noticed |
| U+00E0 | à | `a` | noticed |
| U+00E1 | á | `a` | noticed |
| U+00E2 | â | `a` | noticed |
| U+00E3 | ã | `a` | noticed |
| U+00E4 | ä | `a` | noticed |
| U+00E5 | å | `a` | noticed |
| U+00E6 | æ | `ae` | noticed |
| U+00E7 | ç | `c` | noticed |
| U+00E8 | è | `e` | noticed |
| U+00E9 | é | `e` | noticed |
| U+00EA | ê | `e` | noticed |
| U+00EB | ë | `e` | noticed |
| U+00EC | ì | `i` | noticed |
| U+00ED | í | `i` | noticed |
| U+00EE | î | `i` | noticed |
| U+00EF | ï | `i` | noticed |
| U+00F0 | ð | `d` | noticed |
| U+00F1 | ñ | `n` | noticed |
| U+00F2 | ò | `o` | noticed |
| U+00F3 | ó | `o` | noticed |
| U+00F4 | ô | `o` | noticed |
| U+00F5 | õ | `o` | noticed |
| U+00F6 | ö | `o` | noticed |
| U+00F7 | ÷ | `/` | noticed |
| U+00F8 | ø | `o` | noticed |
| U+00F9 | ù | `u` | noticed |
| U+00FA | ú | `u` | noticed |
| U+00FB | û | `u` | noticed |
| U+00FC | ü | `u` | noticed |
| U+00FD | ý | `y` | noticed |
| U+00FE | þ | `th` | noticed |
| U+00FF | ÿ | `y` | noticed |

**Windows-1252**

| Code point | Character | Becomes | Notice |
| --- | --- | --- | --- |
| U+0152 | Œ | `OE` | noticed |
| U+0153 | œ | `oe` | noticed |
| U+0160 | Š | `S` | noticed |
| U+0161 | š | `s` | noticed |
| U+0178 | Ÿ | `Y` | noticed |
| U+017D | Ž | `Z` | noticed |
| U+017E | ž | `z` | noticed |
| U+0192 | ƒ | `f` | noticed |
| U+02C6 | ˆ | `^` | noticed |
| U+02DC | ˜ | `~` | noticed |
| U+2013 | – | `-` | silent |
| U+2014 | — | `--` | silent |
| U+2018 | ‘ | `'` | silent |
| U+2019 | ’ | `'` | silent |
| U+201A | ‚ | `'` | silent |
| U+201C | “ | `"` | silent |
| U+201D | ” | `"` | silent |
| U+201E | „ | `"` | silent |
| U+2022 | • | `*` | noticed |
| U+2026 | … | `...` | silent |
| U+2039 | ‹ | `'` | silent |
| U+203A | › | `'` | silent |
| U+2122 | ™ | `(TM)` | noticed |

**Combining marks**

| Code point | Character | Becomes | Notice |
| --- | --- | --- | --- |
| U+0300 | ◌̀ *combining grave accent* | *(removed)* | noticed |
| U+0301 | ◌́ *combining acute accent* | *(removed)* | noticed |
| U+0302 | ◌̂ *combining circumflex accent* | *(removed)* | noticed |
| U+0303 | ◌̃ *combining tilde* | *(removed)* | noticed |
| U+0308 | ◌̈ *combining diaeresis* | *(removed)* | noticed |
| U+030A | ◌̊ *combining ring above* | *(removed)* | noticed |
| U+030C | ◌̌ *combining caron* | *(removed)* | noticed |
| U+0327 | ◌̧ *combining cedilla* | *(removed)* | noticed |

These Latin-1 and Windows-1252 characters are deliberately not in the table, so each becomes `[?]`, as does every character not listed at all: ¢ (U+00A2), £ (U+00A3), ¤ (U+00A4), ¥ (U+00A5), § (U+00A7), ¨ (U+00A8), ¬ (U+00AC), ¯ (U+00AF), ° (U+00B0), ² (U+00B2), ³ (U+00B3), µ (U+00B5), ¶ (U+00B6), · (U+00B7), ¸ (U+00B8), ¹ (U+00B9), ¼ (U+00BC), ½ (U+00BD), ¾ (U+00BE), † (U+2020), ‡ (U+2021), ‰ (U+2030), € (U+20AC).

The table's last column says whether reading the character in a file is a repair the writer is told of. Typographic
punctuation and the no-break space, which other editors write freely, are spelled in ASCII **silently**, as before
ADR 0028, so a book edited in TextEdit opens normally. For every other entry, each part of the file gets one notice
listing the characters it had transliterated, and one for those it had replaced with `[?]` (§5.3). So a book holding
accented letters or symbols, which Scene It never writes, opens as repaired: read-only, with its original kept when
the writer makes it editable (ADR 0024).

The serializer writes UTF-8 with no byte-order mark, `\n` line endings, and **exactly one** `\n` at the end of the
file. Since it never writes a character outside the allowed set (the model mustn't contain one, §7.5), the file it
writes is pure ASCII.

### 1.3 Lines, blank lines and trimming

After splitting, every physical line is **trimmed**:

1. Leading spaces are removed.
2. Trailing spaces are removed, except an *escaped* space: a space preceded by an odd-length run of `\`.
3. **Stripped-space tolerance †:** if the line now ends in an odd-length run of `\`, a space is appended. Many editors
   strip trailing whitespace on save, which would turn our escaped space `\␠` into a bare `\`; this rule reads that
   `\` as the space it was. (A literal backslash at the end of a line is always written `\\`, an even run.)

A **blank line** is one that is empty after trimming. Blank lines separate paragraphs and entries; runs of several
blank lines mean the same as one. Body and notes paragraphs keep their own untrimmed text until §3 trims each of
their lines the same way, so indentation never matters anywhere.

### 1.4 Headings

A trimmed line is **heading-shaped** if it is 1–6 `#` characters followed by either the end of the line or a space.
`#hashtag` and `####### x` are not headings; they're text. What a heading means:

| Heading | Meaning | Where it's legal |
| --- | --- | --- |
| `## <title>` or `##` | Starts a scene (§2.1) | Anywhere |
| `# Boneyard` (name case-insensitive) | The scenes after it are the Boneyard | Once |
| `### Notes`, `### Comments`, `### Marks` (names case-insensitive) | Starts that subsection of the current scene (§2.4) | Inside a scene |
| `### Unparsed` | Starts an Unparsed section (§5) | Inside a scene, or before the first scene / between `# Boneyard` and the first Boneyard scene (book-level) |
| Anything else heading-shaped: another `#` or `###` name, `####`–`######`, a second `# Boneyard`, `### Notes` outside a scene | **Not understood.** The line becomes a `[line]` error entry (§5) of the current scene, or of the book if there's no current scene. **The current section doesn't change** †, so a mistyped `### Note` leaves the text after it where it was (in the body, say) rather than losing it. | — |

### 1.5 Front matter

```
---
title: My Novel
format: 2
---
```

It *looks* like YAML but isn't: there's no quoting, and a value is simply the rest of the line.

| Rule | Detail |
| --- | --- |
| Opening | The first non-blank line of the file must be exactly `---` (after trimming). Otherwise there's no front matter: the book gets the defaults below, and the file's content is read from the first line as the preamble (§1.6). |
| Closing | The next line that is exactly `---`. If a heading-shaped line or the end of the file comes first, the front matter ends there, silently †; the closing `---` is written back on the next save. |
| Lines | `key: value`. A key is one or more ASCII letters, matched case-insensitively. The value is everything after the first `:`, trimmed (§1.3), then field-unescaped (§4.1). Blank lines are ignored. |
| `title` | The book's title (plain text, may be empty). **Missing → `Untitled`** † plus a notice. |
| `format` | A decimal integer: ASCII digits, optionally after one `+` (`03` and `+2` are numbers; leading zeros and the `+` are dropped on save). A number too large for the implementation counts as larger than any format, so the file reads as newer, never as damaged. **Missing → read as 2**, plus a notice. **Not 2 → read as 2 anyway**, plus a notice naming the number (§10 Q7). Not an integer (`-3`, `3.0`, `two`) → the line is a `[front matter]` error entry, and then it's missing. |
| Unknown key, duplicate key, or a line that isn't `key: value` | A `[front matter]` error entry, kept verbatim. The first occurrence of a key wins. The review copy's `export` and `exported` keys are known only when a copy is read for review ([review-format.md §2.4](review-format.md#24-reading-a-copy-review-copy-mode)); in a book they're unknown keys like any other. |

**Written as:** `---⏎title: <title>⏎format: 2⏎---⏎`, with `title:` (no trailing space) for an empty title. The
title is field-escaped (§4.1).

### 1.6 The preamble

Everything between the front matter and the first `## ` heading is the *preamble*. Its only legal content is a
book-level `### Unparsed` section (§5). Any other non-blank line there (prose, a stray `### Notes`, a list) becomes a
book-level `[line]` error entry. The same applies to lines between `# Boneyard` and the first Boneyard scene.

### 1.7 Blocks: the canonical layout

The serializer writes the file as a list of **blocks** joined by one blank line (`\n\n`), followed by a final `\n`.
The blocks, in order:

1. The front matter (4 lines).
2. The book-level Unparsed block, if any: `### Unparsed` and its entries.
3. For each story scene, its blocks (§2).
4. If the Boneyard isn't empty: the line `# Boneyard`, then each Boneyard scene's blocks.

A scene's blocks are:

| Block | Content | Written when |
| --- | --- | --- |
| Header | `## <title>`, `id: …`, `modified: …`, then `tags: …` if the scene has tags | Always |
| Body paragraph | One line per paragraph (§3.5) | One block per body paragraph |
| Notes paragraph | The first notes paragraph's block starts with the line `### Notes` | One block per notes paragraph |
| Comments | `### Comments` then one line per comment | The scene has comments |
| Marks | `### Marks` then one line per mark | The scene has marks |
| Unparsed | `### Unparsed` then one line per entry | The scene has error entries |

So `### Notes` is followed directly by the first notes paragraph, with no blank line, as in ADR 0022's example.

### 1.8 The Boneyard

`# Boneyard` (the name matched case-insensitively, then trimmed) ends the story and the current scene. Every scene after
it is in the Boneyard, in file order, which is most-recently-cut first. A second `# Boneyard` is a `[line]` error
entry and changes nothing.

---

## 2. Scenes

### 2.1 The heading and the title

| Rule | Detail |
| --- | --- |
| Shape | A heading-shaped line with exactly two `#`: `##` alone, or `## ` followed by the title. |
| Title text | The text after `## `, read as **one paragraph line** with §3's rules (trimming, escapes, style delimiters). Style delimiters are then **dropped** † and only the characters kept, following ADR 0015's normalizing load: `## The *ferry*` reads as the title `The ferry`, and the next save writes `## The ferry`. |
| Empty title | Written `##` (no trailing space). `## ` with nothing after it reads the same way. |
| Written as | `## ` + the title with `\`, `*`, `_`, `~` escaped by a backslash, and a space at the first or last position written `\␠`. No line-start escapes are needed: the line starts with `## `. |

A `##` heading always starts a new scene, wherever it appears. Typing `## Interlude` in the middle of a scene's body
splits that scene in two (see §6).

### 2.2 The metadata block

`key: value` lines **directly under the heading**, with no blank line between, as ADR 0022 says.

| Rule | Detail |
| --- | --- |
| Extent | The block is the run of consecutive lines right after the heading that are *key-shaped*: one or more ASCII letters, then `:`. It ends at the first line that isn't (a blank line, a heading, or prose). A non-blank line that ends the block is the start of the body. |
| Keys | Matched case-insensitively. Written lowercase, in the order `id`, `modified`, `tags`. |
| Value | The rest of the line after the first `:`, trimmed (§1.3). |
| Duplicate key | The first wins. Each later one is a `[metadata]` error entry. |
| Unknown key | A `[metadata]` error entry (`Mara: hello` directly under a heading is one). |
| Bad value | A `[metadata]` error entry; then the key counts as missing. |

| Key | Value format | Missing (or bad) |
| --- | --- | --- |
| `id` | 1–64 characters from `A–Z a–z 0–9 _ -` †. Case-sensitive, compared byte for byte. New ids are 26-character ULIDs; hand-made ids like `01JC4K` are fine. Unique across the whole book (story and Boneyard). | A fresh ULID, plus a notice. A **duplicate** of an earlier scene's id (in file order) is replaced by a fresh ULID, plus a notice naming the old id. |
| `modified` | `YYYY-MM-DDTHH:MM:SS±HH:MM`: whole seconds, numeric offset (the `Timestamp` type's format). Year 0000–9999; the date must exist; offset at most ±23:59. **Accepted, then written in canonical form †:** `Z` for `+00:00`. | The time the book was opened, in the local time zone, plus a notice. |
| `tags` | Tags separated by `,`. Each tag is trimmed, then field-unescaped (§4.1): a comma inside a tag is `\,` and a backslash is `\\`. An unescaped `#` at the start of a tag is dropped silently (tags are stored without `#`, PLAN §8.3). Empty items (`a,,b`) are dropped silently. Order and duplicates are kept as written. | No tags, silently. The line is **omitted** when there are no tags (as in the demo book), so its absence is normal † (§10 Q9). |

**Written as:** `id: <id>`, `modified: <timestamp>`, and, if there are tags, `tags: ` + the tags joined by `, `. In each
tag, `\` → `\\`, `,` → `\,`, a newline → `\n`, a leading `#` → `\#`, and a space at the tag's first or last position
→ `\␠`.

### 2.3 The body

The body is every line after the metadata block up to the scene's first subsection heading (or the next `##` /
`# Boneyard` / end of file). It's a sequence of paragraphs (§3). An empty body is simply no paragraph blocks.

### 2.4 Subsections

| Subsection | Holds | Content rule |
| --- | --- | --- |
| `### Notes` | The scene's notes | Paragraphs, exactly like the body (§3) |
| `### Comments` | Comment entries | Entries (§4). Blank lines between entries are ignored. |
| `### Marks` | Color and highlight marks | Entries (§4) |
| `### Unparsed` | Error entries | Entries (§5) |

- **Written** in the fixed order Notes, Comments, Marks, Unparsed. An empty subsection isn't written.
- **Read** in any order, and any of them may repeat: repeated Notes sections append their paragraphs in file order;
  repeated Comments, Marks and Unparsed sections append their entries in file order. The next save writes one of each,
  in the fixed order.
- Body text can't follow a subsection: once a scene has had a `###` heading, the only way back to the body is a new
  `##` scene. Prose under `### Comments`, `### Marks` or `### Unparsed` becomes error entries (§4.8, §5).
- An unknown `###` heading is a `[line]` error entry and doesn't change the current section (§1.4).

---

## 3. Paragraphs and inline markup

This section applies to body paragraphs, notes paragraphs, and (with styles dropped) scene titles.

### 3.1 Paragraphs and soft line breaks

- A **paragraph** is a maximal run of consecutive non-blank, non-heading lines in the body or the notes.
- **Wrapped lines are joined †.** A paragraph spread over several lines (because the writer's editor hard-wraps) is
  read as one: each line is trimmed (§1.3) and the lines are joined with **a single space**. The next save writes the
  paragraph on one line. A paragraph never contains a line break; the model can't hold one.
- Escapes are resolved per physical line, before joining, so a backslash at the end of a line never escapes the join
  space.

### 3.2 Empty paragraphs †

The model allows an empty paragraph (the writer pressed Return twice), and it counts in offsets (it adds a `\n` to
the plain text, §3.6), so it must survive a save. Blank lines can't express it: any number of them is one separator.

- **Written as** a paragraph whose only line is `<br>`.
- **Read:** a paragraph consisting of exactly one line that is `<br>`, `<br/>` or `<br />` (case-insensitive, after
  trimming) is an empty paragraph. `<br>` inside a longer paragraph is ordinary text.
- Markdown previewers render `<br>` as a blank line, so the file still looks right in them. See §10 Q1.

### 3.3 Escapes (reading)

Within a paragraph line, a backslash followed by **an ASCII punctuation character or a space** stands for that
character, as literal text:

```
! " # $ % & ' ( ) * + , - . / : ; < = > ? @ [ \ ] ^ _ ` { | } ~  and ␠
```

An escaped character is never markup and never counts as whitespace for §3.4. A backslash followed by anything else (a
letter or a digit) is itself literal, and the next character is read normally: `C:\logs` reads as
`C:\logs`. That form is accepted, but the serializer would write `C:\\logs`.

### 3.4 Bold, italic and strikethrough (reading)

The styles are **toggles** †. `**` toggles bold, `*` toggles italic, `~~` toggles strikethrough. Because toggles
commute, any overlap of the three styles is expressible, and the reader needs no nesting rules. Styles never carry
over from one paragraph to the next.

The algorithm, per paragraph (after §3.1's joining; the join space is an ordinary unescaped space):

1. **Delimiter runs.** Find every maximal run of unescaped `*`, and every maximal run of unescaped `~`.
2. **Free-standing runs are text.** A run with whitespace (an unescaped space) or the paragraph's start on its left,
   **and** whitespace or the paragraph's end on its right, is literal text. This keeps a scene break `* * *` or
   `***` on its own line, and `a * b`, as typed.
3. **Expansion.** A `*` run of length *n* is ⌊n/2⌋ bold toggles followed, if *n* is odd, by one italic toggle. A `~`
   run of length *n* is ⌊n/2⌋ strike toggles followed, if *n* is odd, by a literal `~`. So `***` is bold + italic, and
   a lone `~` is just a tilde.
4. **Unbalanced toggles are text.** For each style, if the paragraph has an odd number of its toggles, the **last**
   one is literal text (`**`, `*` or `~~`) in its place.
5. **Apply.** Walk the paragraph left to right, flipping each style at its toggles. Each character gets the styles in
   force at that point.

Unbalanced or odd markup is **never an error**: `He said **wow.` reads as the literal text `He said **wow.`, and the
next save writes `He said \*\*wow.`.

Known hand-editing hazard: `2*3*4` reads as `2`, italic `3`, `4`, as it would in most Markdown. Escape it (`2\*3\*4`)
if you mean the asterisks. Scene It always escapes them when it saves, so this only affects what you type yourself.

### 3.5 Writing a paragraph (serializing)

Input: the paragraph's runs. Only the styles matter here; colors, highlights and comments are written separately
(§4).

1. **Empty paragraph** → the line `<br>`. Stop.
2. **Delimiters.** Before each run, and after the last one, compare the styles in force before and after the
   boundary. Write the **closing** delimiters first, in the order strike `~~`, italic `*`, bold `**`, then the
   **opening** delimiters in the order bold `**`, italic `*`, strike `~~`. A boundary where the styles don't change
   writes nothing; adjacent runs that differ only in color or comments merge.
3. **Characters.** `\` → `\\`, `*` → `\*`, `_` → `\_`, `~` → `\~`. A space is written `\␠` when it is (a) the
   paragraph's first or last character, or (b) written immediately after a delimiter run that itself immediately
   follows a space or the start of the line. In (b), "a space" is the paragraph's character, however it was
   written: a delimiter run right after an escaped `\␠` counts as following a space, so `" "`, `bold " x"` is
   written `\␠**\␠x**`. Rule (b) guarantees that no delimiter the serializer writes is free-standing (§3.4
   step 2). Every other character is written as itself.
4. **Line-start escapes.** If the resulting line starts with `#`, starts with `- `, starts with `---`, is exactly `-`,
   or is (case-insensitively) `<br>`, `<br/>` or `<br />`, a `\` is put in front of it. Unescaped, these could read
   as structure: a heading, an entry, front matter, an empty paragraph.

ADR 0022 also lists `key:` directly under a heading as structure to escape. No escape is needed: the serializer
always writes a blank line between a scene's metadata block and its first paragraph (§1.7), so a paragraph is never
directly under a heading and a body line like `Mara: hello` can't be read as metadata.

`_` is escaped although Scene It doesn't read it as markup, because other Markdown viewers would. Unescaped `_`, a lone
`~`, a free-standing `*` and an unescaped `- ` or `---` at the start of a paragraph line all read as **literal text**,
and the next save escapes them.

| Runs | Written |
| --- | --- |
| `bold "already"` | `**already**` |
| `bold+italic+strike "never"` | `***~~never~~***` |
| `"when "`, `bold "the house… and "`, `bold+italic "leaving"`, `italic " still… game."` | `when **the house… and *leaving** still… game.*` |
| `"Wait "`, `bold " for"`, `" it."` | `Wait **\ for** it.` (rule 3b) |
| `"He said. "` (trailing space) | `He said.\␠` |
| `"#7 was on the gate"` | `\#7 was on the gate` |
| `"5*3 and file_2 at C:\"` | `5\*3 and file\_2 at C:\\` |
| `"* * *"` | `\* \* \*` |

The same rules, minus delimiters and line-start escapes, write titles (§2.1).

### 3.6 Plain text, and what offsets count

Comments and marks address text by character offsets into a **plain text**:

- **A scene's body plain text** is the text of its paragraphs (characters only, all markup and escapes resolved)
  joined by a single `\n`. An empty paragraph contributes the empty string, so two paragraphs around it are separated
  by `\n\n`. A body with no paragraphs has the empty plain text.
- **A scene's notes plain text** is defined the same way over the notes paragraphs.
- The title is never part of either.
- Offsets count characters (§1.2) from 0.

Example: `He found the **letter**.` followed by the paragraph `Mara *watched*.` has the plain text
`He found the letter.\nMara watched.`; `letter` is `c13-19` and `Mara` is `c21-25`.

### 3.7 Hand-editing gotchas

Three things that surprise writers typing in another editor. Scene It never writes them this way itself.

| You type | Scene It reads | To get what you meant |
| --- | --- | --- |
| `C:\` at the end of a paragraph line | `C:` and a space: a trailing `\` is an escaped space whose space an editor stripped (§1.3) | `C:\\` |
| `see C:\new` in a comment's text | `see C:`, a line break, `ew`: `\n` is a line break in comment text, tags and the book title (§4.1) | `see C:\\new` |
| `## Chapter 2*3*4` | the title `Chapter 234`: `*3*` is italic, and formatting in a title is dropped (§2.1) | `## Chapter 2\*3\*4` |

---

## 4. Comments and marks

### 4.1 Entries, separators and field escapes

These rules are shared by Comments, Marks and Unparsed sections (and by the archive index's fields).

| Rule | Detail |
| --- | --- |
| Entry | A line starting `-` followed by a space (or a line that is exactly `-`). Written `- ` + fields. |
| Continuation † | A non-blank, non-heading line that doesn't start with `- `, directly after an entry line (no blank line between), continues it: it's joined to the entry with a single space. This undoes an editor's hard wrap. A non-entry line with no entry directly above it is a stray line (§4.8). |
| Separator | `|`, with any number of spaces either side. Written ` | `. |
| Field escapes (read) | `\n` → a newline. `\` + ASCII punctuation or space → that character (`\\`, `\"`, `\,`, `\|`, `\␠` …). `\` + anything else → a literal backslash. Quotes are the exception: they have only three escapes (§4.3). |
| Field escapes (write) | `\` → `\\`; newline → `\n`; inside a quote also `"` → `\"`; in a free-text field also a space at its first or last position → `\␠`. Nothing else is escaped: `|` in a comment's text is literal because the text is the last field. |

### 4.2 Ranges

| Rule | Detail |
| --- | --- |
| Syntax | `c<start>-<end>` addresses the body's plain text; `notes c<start>-<end>` addresses the notes' plain text. `c` and `notes` are case-insensitive; the numbers are decimal (leading zeros accepted, never written). |
| Meaning | **Start inclusive, end exclusive**: the characters at offsets `start … end−1`. `c13-19` is 6 characters. Chosen because ADR 0022's own example and the demo book use it (`"letter"` is `c13-19`), the length is simply `end − start`, adjacent ranges share an endpoint, and it's the convention of Swift's `..<` and most string APIs. |
| Valid | `0 ≤ start < end ≤ length` of the addressed plain text, and the range contains at least one character other than `\n`. |
| Spanning paragraphs | A range may span paragraph breaks. The `\n` characters inside it are part of its quote, but they carry no formatting: a comment or mark covers the non-`\n` characters in its range. |
| Lists | A field may hold several ranges separated by `,` (written `, `), for a comment whose text isn't contiguous (typing inside a commented passage leaves a gap, PLAN §8.1). Each range carries its own `notes` prefix if it needs one, and one entry may mix body and notes ranges. |
| Written as † | The covered characters, grouped into maximal ranges. A gap consisting only of `\n` characters is bridged, so a passage commented across three paragraphs is one range. All body ranges first, then all notes ranges, each in ascending order. |

### 4.3 Quotes

Each range is followed by its **quote**: the exact plain text at the range, in double quotes. With several ranges
the quotes are a matching list, separated by `,` (written `, `). Inside a quote, `\"` is a quote mark, `\\` a
backslash and `\n` a paragraph break; everything else, including `|`, `*` and `,`, is literal. That includes any
other backslash: `"a\,b"` is the four characters `a\,b`, not `a,b`, so a quote copied from the text keeps what it
copied.

The quote must equal the plain text at the range **exactly**, character for character after unescaping. There is no
re-anchoring (ADR 0022): if you edit the text a comment points at, fix its range and quote too, or mark the comment
`detached` (§4.5). Formatting markup never appears in a quote: the quote of `the **letter**` is `"the letter"`.

### 4.4 Comment entries

```
- <id> | <color> | <created> | <ranges> | <quotes> | <text>
- c1 | purple | 2026-10-31T20:40:00-07:00 | c332-338 | "letter" | Too early for this reveal?
- c5 | blue | 2026-11-01T09:20:00-08:00 | c236-254, c272-283 | "the engine coughed", "swore at it" | Too much | "noise" here?
```

| Field | Rule |
| --- | --- |
| `id` | Same character set as scene ids (§2.2). Unique within its scene; scenes may reuse each other's comment ids. |
| `color` | One of the seven palette names (§4.6), black included: a comment can be any of them. Case-insensitive; `grey` is read as `gray` † (PLAN §8.1's search accepts both). |
| `created` | A timestamp, as `modified` (§2.2). |
| `ranges`, `quotes` | §4.2, §4.3. |
| `text` | The rest of the logical line after the last separator, trimmed and field-unescaped. Plain text, one line (a newline in the model is written `\n`). May be empty: then the entry ends `"…" |`. |

Comments are written in the model's order (the order of the scene's comment list), which the reader preserves.

### 4.5 Detached comments

PLAN §8.1 keeps a comment whose text has all been deleted as **detached**. It has no range and no quote:

```
- <id> | <color> | <created> | detached | <text>
- c6 | pink | 2026-10-29T18:00:00-07:00 | detached | Cut the dream sequence?
```

`detached` is case-insensitive. It's a valid comment, not an error: it loads into the Comments tab's Detached group.
It's also the writer's escape hatch: when you've rewritten the text a comment pointed at and don't want to work out the
new range, replace its range and quote with `detached`.

A comment with ranges that don't match (§4.8) is **an error**, not detached. The parser never decides on its own that
a comment has lost its text.

### 4.6 Mark entries

```
- color <name> | <ranges> | <quotes>
- highlight <name> | <ranges> | <quotes>
- color purple | c45-58 | "harbor lights"
- highlight green | notes c10-21 | "tide tables"
```

Palette names (PLAN §6.2), case-insensitive, `grey` read as `gray` †:

| Name | `color` | `highlight` | `comment` |
| --- | --- | --- | --- |
| `black` | Accepted; means *no color* (ADR 0013). Never written. | **Error** | Yes |
| `purple`, `red`, `blue`, `green`, `gray`, `pink` | Yes | Yes | Yes |

**Written as †:** for each kind (color, highlight) and each name, one entry per maximal range of characters with that
color or highlight (gaps of only `\n` bridged, as in §4.2), with a single range. Sorted by: body before notes, then
start offset, then `color` before `highlight`. (One entry can't tie with another on all three: a character has one
color and one highlight.)

### 4.7 How entries apply, and overlap

After a scene's body and notes are read, its marks are applied in file order, then its comments:

- A **comment** covers every non-`\n` character in its ranges. Comments may overlap each other and anything else.
- A **color mark** sets the color of every non-`\n` character in its ranges; `color black` clears it. If two color
  marks overlap, the one **later in the file wins** for the shared characters † (the serializer never writes such
  overlaps). Highlight marks work the same way, independently of color.
- Overlaps between a comment and a mark, or between a color and a highlight, are normal.
- The result is split into runs: maximal stretches of characters with identical styles, color, highlight and set of
  comments.

### 4.8 What makes an entry an error

Any of the following makes the whole entry (its logical line, verbatim after trimming) an error entry, tagged
`[comments]` or `[marks]` by the section it was in. It then has no effect on the text.

| # | Problem | Example |
| --- | --- | --- |
| E1 | Stray line: not an entry and no entry directly above it | `Remember to fix this` under `### Comments` after a blank line |
| E2 | Wrong number or order of fields; a field empty that mustn't be | `- c1 | purple | letter` |
| E3 | Bad comment id, or an id already used by an earlier comment of the same scene | `- c 1 | …` |
| E4 | Unknown palette name; `highlight black`; a mark kind other than `color` or `highlight` | `- c1 | mauve | …`, `- underline red | …` |
| E5 | Bad timestamp | `2026-10-31 20:40` |
| E6 | Bad range syntax | `c13–19` (an en dash, which reads as `-`, is fine; `c13to19` isn't) |
| E7 | A range out of bounds, empty or backwards, or covering only `\n` | `c19-13`, `c400-410` in a 300-character body |
| E8 | The number of quotes differs from the number of ranges; a quote unterminated | `"letter` (a truncated line) |
| E9 | **A quote that doesn't equal the plain text at its range** | `c13-19 | "lettre"` |
| E10 | Anything left over after a mark's quotes | `- color red | c0-3 | "The" | extra` |

---

## 5. Unparsed entries and the Errors tab

### 5.1 The entry format

Every error entry is one line:

```
- [<tag>] <payload>
```

| Tag | Payload | Made by |
| --- | --- | --- |
| `front matter` | The front-matter line, verbatim (trimmed) | §1.5 |
| `metadata` | The metadata line, verbatim | §2.2 |
| `comments` | The comment entry's logical line, verbatim, including its `- ` | §4.8 |
| `marks` | The mark entry's logical line, verbatim | §4.8 |
| `line` | A line that fits nowhere: preamble text, an unknown heading, a stray line in an Unparsed section, a malformed Unparsed entry | §1.4, §1.6 |
| `notice` | A message from the parser about something it repaired (§5.3) | §5.3 |

- The tag is matched case-insensitively and written lowercase. A payload is written after one space; an empty payload
  is written as `- [<tag>]`.
- A line in an Unparsed section that isn't `- [<one of the six tags>] …` is kept whole as a `[line]` entry, so
  `- [foo] x` becomes `- [line] - [foo] x`. Continuation lines (§4.1) apply here too. That includes a line typed
  directly under a well-formed entry: it's joined to that entry's payload, so `- [line] kept` followed by `stray`
  reads as the entry `[line] kept stray`, and the next save writes it on one line. The text is kept, in the entry
  above it; leave a blank line before a stray line to keep it as an entry of its own.
- Payloads are **never re-parsed** on load: an entry stays an entry, unchanged, across any number of saves, until the
  writer deletes it or repairs it (§5.4). They need no escaping: a payload is a single line of already-filtered text.
- Entries belong to the scene they were found in, and travel with it to and from the Boneyard. Entries found outside
  any scene belong to the book and are written in the book-level Unparsed section after the front matter.

### 5.2 Order

Within a scene (or the book), entries are kept in this order:

1. Entries in file order of the line that produced them: those read from `### Unparsed` sections, and those produced
   by failed front-matter, metadata, comment, mark and heading lines, interleaved by position in the file.
2. Then the notices produced at the end of the scene, in the order: id (missing or duplicate), modified, replaced
   characters. For the book: encoding, title, format, replaced characters.

The serializer writes entries in the model's order, so the order is stable from then on.

### 5.3 Notices

A notice records a repair the parser made with nothing left to keep verbatim. It's an error entry like any other: it
stays in the file until the writer deletes it. The texts are proposals †; wording on screen is the owner's call
(§10 Q5).

| Situation | Where | Payload |
| --- | --- | --- |
| Bytes weren't valid UTF-8 | Book | `Some of this file wasn't valid UTF-8: <n> byte(s) were read as Windows-1252 characters.` |
| Characters the transliteration table spelled in ASCII with a notice (§1.2; not typographic punctuation or the no-break space) | The scene (or book) whose lines held them | `Characters outside plain ASCII were changed to their nearest ASCII: U+00E9, U+201C.` (distinct code points, in order of first appearance, uppercase hex, at least 4 digits) |
| Characters with no entry in the table | The scene (or book) whose lines held them | `Characters with no ASCII form were replaced with [?]: U+1F30A, U+03B1.` (as above). It follows the transliteration notice when a part has both. |
| No `title` | Book | `The book had no title, so it was called "Untitled".` |
| No `format` | Book | `The file had no format line; it was read as format 2.` |
| `format` not 2 | Book | `The file says format <n>; this version of Scene It reads format 2.` |
| No (valid) `id` | Scene | `This scene had no id, so it was given <new id>.` |
| Duplicate `id` | Scene | `This scene's id <old id> was already used by an earlier scene, so it was given <new id>.` |
| No (valid) `modified` | Scene | `This scene had no modified date, so it was set to <timestamp>.` |

The parser takes the current time, the local time zone and an id generator as inputs, so tests can make the defaults
deterministic.

### 5.4 The Errors tab

- **One row per entry**, in the order book, story scenes, Boneyard scenes, and within each in model order. A row shows
  the scene title, the payload, and a **reason**.
- **The reason is derived, never stored †.** For `front matter`, `metadata`, `comments` and `marks` entries, the app
  re-parses the payload in its context (that scene's current plain text and comment ids) and names the first rule it
  breaks (§4.8's E-numbers, or the metadata/front-matter rule). `line` and `notice` entries show a fixed explanation.
  So the file holds only what the writer can see and edit.
- **Delete** removes the entry; the next save drops its line.
- **Repair †** (`front matter`, `metadata`, `comments`, `marks` only): the writer edits the payload, and the app
  re-parses it in context with the same code the loader uses. If it parses, the entry leaves Unparsed and takes effect
  (the comment or mark is added; the metadata or front-matter value replaces the current one). If it doesn't, the
  entry stays, with the edited payload. `line` and `notice` entries can only be deleted (or copied).
- A writer can make the same repairs in a text editor: move the payload back into its section and fix it.

---

## 6. The parser never fails: damage and its result

Every byte sequence parses to a book. Damage costs what it touches, at most the scene it's in, never the book.
(Breaking a scene's `##` line merges the scene into the one before it, so that one is touched too.)

Three rules reach further, and they're the only exceptions:

1. **A duplicate id renames a later scene.** If damage gives an earlier scene the id of a later one, the later one
   (in file order) gets a fresh id and a notice (§2.2), though its own lines are untouched.
2. **An early `# Boneyard` moves scenes.** A `# Boneyard` heading typed or pasted before the real one starts the
   Boneyard there: the story scenes after it move to the Boneyard, and the real heading becomes a second one, a
   `[line]` entry of the scene it used to end (§1.8).
3. **A broken `# Boneyard` moves scenes back.** If the real `# Boneyard` line is damaged (`# Boneyrd`), it's an unknown
   heading, a `[line]` entry, and the Boneyard scenes after it are read as story scenes.

In every case the scenes' text, notes, comments and marks are read exactly as before.

| Damage | Result |
| --- | --- |
| **Empty file** (0 bytes) | A book titled `Untitled` with no scenes; notices: no title, no format. |
| **Truncated file** | Everything before the cut parses normally. A cut inside a body or notes paragraph shortens it (undetectable). A cut inside an entry line makes that entry an error (E2/E8). A cut inside a multi-byte character leaves invalid UTF-8: the encoding notice. A cut inside the front matter ends it (§1.5). Whatever came after the cut is gone; the backups (ADR 0005) hold it. |
| **Missing final newline**, extra blank lines, `\r\n` or `\r` endings | Read normally, silently. |
| **Missing front matter** | Defaults (`Untitled`, format 2) and their notices; the file is read from the top as the preamble. |
| **Front matter not closed** | It ends at the first heading-shaped line; silent. |
| **Unknown or duplicate front-matter key** | `[front matter]` entry. |
| **Text before the first scene** | Each non-blank line is a book-level `[line]` entry. |
| **Garbage between scenes** | It belongs to the previous scene's current section. In the body or notes it's text. Under Comments or Marks it's E1 or a continuation (which then usually fails as E2). In Unparsed it's a `[line]` entry. |
| **Metadata garbled** | Bad value → `[metadata]` entry plus the default and its notice. Unknown key → `[metadata]` entry. |
| **Blank line between `##` and `id:`** | The metadata lines are no longer directly under the heading, so they're read as the first body paragraph (visible on the page); the id and date get defaults with notices. Deleting that paragraph and the notices, or fixing the file, repairs it. |
| **Duplicate scene id** | The later scene (in file order) gets a fresh id and a notice. |
| **A `##` heading inside the body** | It starts a new scene with that title. The new scene has no metadata (two notices) and takes everything after the heading: the rest of the body and the original scene's subsections. Comments and marks whose ranges pointed past the split now address the new scene's shorter text, so most fail as E7/E9 and land in its Unparsed section. Nothing is lost; the damage stays in the two scenes. |
| **An unknown heading inside the body** (`### Note`, `#### Part 2`, `# Act 1`) | A `[line]` entry; the text around it stays in the body. |
| **A known `###` heading inside the body** (`### Notes`) | It really is a subsection: the text after it becomes notes. |
| **Invalid UTF-8 byte** | Decoded as Windows-1252 (§1.2); one book-level notice. |
| **A disallowed character** (emoji, Greek, a control character, U+2028) | `[?]` in its place; one notice per scene listing the code points. |
| **Typographic punctuation, a no-break space** (“ ” ‘ ’ — – …) | Spelled in ASCII silently (§1.2). It changes lengths (— becomes `--`), so comments and marks after it in that scene may then fail E9. |
| **Accented letters and other symbols in the table** (é ñ © •) | Spelled in ASCII by the transliteration table (§1.2); one notice per scene listing the code points, so the book opens read-only (ADR 0024). A combining accent becomes nothing, which changes lengths as above. |
| **A wrong range, or a quote that no longer matches** | E7/E9 → `[comments]`/`[marks]` entry; the text loses only that comment's underline or that color. |
| **An unknown palette name** | E4 → entry. |
| **A duplicate comment id in a scene** | The later entry is E3. |
| **A truncated entry line** | E2 or E8 → entry. |
| **Unbalanced `*`, `**`, `~~`** | Literal text (§3.4); silent. |
| **A wrapped paragraph or entry** | Joined (§3.1, §4.1); silent. |
| **A malformed Unparsed line** | Kept whole as a `[line]` entry. |
| **A second `# Boneyard`** | `[line]` entry; ignored. |
| **`format: 3`** (a newer Scene It) | Read as format 2, with a notice; what this version doesn't understand lands in Unparsed (§10 Q7). |
| **A v1 `book.json` renamed to `book.md`** | No front matter, so defaults and notices; every JSON line is a book-level `[line]` entry. Nothing is lost, though nothing is usable either: there's no migration (ADR 0022). |

---

## 7. Canonical form and save verification

### 7.1 What `serialize` produces

The canonical form is exactly what §1.5, §1.7, §2, §3.5, §4 and §5.1 say the serializer writes. In summary:

- UTF-8, no byte-order mark, `\n` line endings, blocks separated by one blank line, one final `\n`, no trailing
  spaces except an escaped one (`\␠`).
- Front matter `title`, `format: 2`. Scene metadata `id`, `modified`, then `tags` only if there are tags.
- One line per paragraph; `<br>` for an empty paragraph.
- Subsections in the order Notes, Comments, Marks, Unparsed, each only if non-empty.
- Comments in model order, with maximal merged ranges; marks one range each, sorted; entries and timestamps in
  canonical spelling.

### 7.2 The save-verification rule

ADR 0022: `serialize(book) → parse → serialize` must produce identical bytes, with no error entries, or the save is
refused. Precisely †:

> Let `b = serialize(book)` and `p = parse(b)`. The save may proceed only if
>
> 1. `p`'s error entries are exactly `book`'s error entries: no new ones;
> 2. `p` **is** `book`, with neighbouring runs of the same format merged (the one change the canonical form makes,
>    §7.3): every title, tag, paragraph, run, comment and entry compares equal; and
> 3. `serialize(p) == b` byte for byte.

A book can legitimately hold error entries it read earlier and the writer hasn't dealt with; those come back from
`### Unparsed` unchanged, so they aren't new. Any other entry means the serializer wrote something the parser doesn't
read back, which is a bug, so the save is refused (§10 Q6).

The book comparison (2) catches what the bytes alone can't: something the model holds that the format can't write
is simply left out, and the bytes are perfectly stable without it. The case that found this: a run carrying a comment
id that the scene's comment list doesn't have. Its ranges are written from the list, so the id is dropped, and the save
is refused instead (Scene It's `VerificationFailure.changed`). Comparing books is exact here because every string in
the model is admitted ASCII (§1.2), where canonically equivalent text is identical text.

### 7.3 Accepted and silently canonicalized on the next save

| Input | Canonical |
| --- | --- |
| `\r\n`, `\r`; a byte-order mark; no or several final newlines; extra blank lines; indentation; trailing spaces | `\n`; none; one; one; none; none |
| Typographic punctuation, no-break spaces, tabs | `"` `'` `--` `-` `...`, spaces, spaces |
| Wrapped paragraphs and entries | One line each |
| Unescaped literal `_`, lone `~`, free-standing `*`, unbalanced delimiters, `\` before a letter | Escaped |
| A paragraph line starting with unescaped `- `, `---` | Escaped |
| Delimiters in another order (`*~~**x**~~*`), redundant toggles (`a****b`) | Canonical order; removed |
| `<br/>`, `<BR />` | `<br>` |
| Formatting in a title | Dropped |
| Upper-case keys, section names, palette names, `grey`, `Detached`, `Notes c…`, `C13-19` | Lower case, `gray` |
| Spacing around `|` and `,`; `- ` with several spaces | ` | `, `, `, `- ` |
| A timestamp with `Z` | `+00:00` |
| Leading zeros in offsets; overlapping, adjacent, unsorted or split ranges; a range starting or ending on `\n` | Merged maximal ranges, ascending |
| Overlapping color marks; `color black`; a mark split into several entries; marks in any order | Re-derived from the characters' colors (§4.6) |
| Subsections in any order, repeated or empty | One each, in order, non-empty only |
| An empty `tags:` line; `#` before a tag; empty tag items | Omitted; dropped; dropped |
| Front matter not closed; keys in another order | Closed; `title`, `format` |
| Runs fragmented in the model | Maximal runs |

### 7.4 Recorded as errors

Everything in §4.8; unknown, duplicate or bad-valued front-matter and metadata keys; missing `id`, `modified`, `title`
and `format` (notices); duplicate scene ids; invalid UTF-8; disallowed characters; unknown headings; lines outside any
section; malformed Unparsed lines.

### 7.5 What the serializer assumes about the model

`serialize` is total, but the verification rule only holds if the model satisfies these invariants. The editor and
store maintain them; a violation shows up as a refused save, never as a silently different file.

- All text (title, tags, paragraphs, comment text, the book title) contains only allowed characters (§1.2). Paragraphs
  and titles contain no line breaks; tags and comment text may (they're written `\n`), though the UI shouldn't produce
  them.
- No empty runs (an empty paragraph has no runs). No empty tags.
- Scene ids are unique in the book; comment ids are unique in their scene; every id matches §2.2's character set.
- Every comment id on a run is in the scene's comment list.
- Error entries have one of the six tags and a payload that is a line as §1.3 leaves it: a single line, no leading
  spaces, no trailing space unless it's escaped (`\␠`), and **never ending in an odd run of `\`** (§1.3 would read
  it back with a space added). That's exactly what reading `- [<tag>] <payload>` produces, so any such payload is
  written and read back unchanged.

---

## 8. The archive index (`Archive/index.md`)

ADR 0022 makes the index tolerant text, one section per filed copy. It reuses this document's machinery: front
matter, `##` sections, `key: value` metadata, tags, field escapes and `### Unparsed`.

```markdown
---
format: 2
---

## save0001.md
filed: 2026-09-14
tags: first draft
scenes: 22
words: 48210
comments: 31

## save0002.md
filed: 2026-10-31
tags: draft 4, before the ending
note: Before the ending rewrite
scenes: 24
words: 51336
comments: 44
```

| Rule | Detail |
| --- | --- |
| Front matter | `format: 2` only. Missing → notice, as in §1.5. Unknown keys → `[front matter]` entries. |
| Section heading | `## save<NNNN>.md`: `save`, four or more decimal digits, `.md`. Any other `##` heading → a book-level `[line]` entry, and the metadata lines under it too. A second section for the same file → `[line]` entries; the first wins. |
| `filed` | `YYYY-MM-DD`, the date the writer gave (editable, PLAN §7.1). Missing or bad → the filed copy's modification date in the local time zone, plus a `[metadata]` entry (bad) or a notice (missing). |
| `tags` | As scene tags (§2.2). Omitted when empty. |
| `note` | Free text, field-escaped (§4.1); a newline is `\n`. Omitted when empty. |
| `scenes`, `words`, `comments` | Non-negative decimal integers. They're a cache of facts about an immutable file, so if one is missing or bad it's **recomputed from the filed copy, silently** †, and written on the next save of the index. |
| Unknown key, duplicate key | `[metadata]` entry in the section's `### Unparsed`. |
| Canonical | Front matter, then sections in ascending file number, each: heading, `filed`, `tags` (if any), `note` (if any), `scenes`, `words`, `comments`, then `### Unparsed` (if any). Blocks joined by one blank line; one final newline. |
| Reconciliation (PLAN §5.5) | A filed copy with no section is listed with no tags, its counts computed, and gets a section on the next index write. A section whose file is missing (or isn't a regular file named exactly so) isn't listed, and its lines are kept as `[line]` entries in the index's own `### Unparsed` on the next index write †. Before a rewrite that changes what was written (new error entries, or such a section), the file is kept as `Archive/index.md.original-<UTC time>.md` †. `NNNN` is one more than the highest existing number up to 999999; higher numbers are ignored. |

The index has no Errors tab of its own; see §10 Q12.

---

## 9. Examples

### 9.1 A complete book

This is built from the demo book `convert.py` generates (the reference the owner has seen), cut down to three story
scenes and one Boneyard scene, and extended to use every feature. Changes from the demo, all deliberate:

1. Only the first three story scenes and the first Boneyard scene are kept.
2. *The ferry*: inline formatting added (italic, overlapping bold and italic, bold+italic+strike). Its text is
   unchanged, so the demo's offsets (`c0-22`, `c332-338`, `notes c114-136`) still hold. Comments `c4` (spans two
   paragraphs, overlaps `c2`, empty text), `c5` (two ranges, `|` and `"` in its text), `c7` (in the notes) and `c6` (detached), and
   three marks, are added.
3. *Arrival*: four paragraphs added after the demo's three, to show escapes, an empty paragraph and a trailing space.
   The demo's `c263-275` still holds.
4. *The letter*: a tag containing a comma, and an Unparsed section with a preserved bad comment and an unknown
   metadata key.
5. A book-level Unparsed entry (an unknown front-matter key).
6. *The brother's boat* gets a comment, `c1`, reusing an id from *The ferry* (ids are per scene).

```markdown
---
title: My Novel
format: 2
---

### Unparsed
- [front matter] author: S. Basu

## The ferry
id: 01JCM9S346Q3D25VT4F5V37E3S
modified: 2026-11-02T09:00:00-08:00
tags: opening, Mara

The ferry left at dawn, and Mara watched the *harbor lights* go out one by one behind her.

She had packed in the dark, *by feel*, the way she used to as a girl when **the house was asleep and *leaving** still seemed like a game.*

Halfway across, the engine coughed and the deckhand swore at it in a language she half remembered. He found the **letter** under the bench an hour later, but by then she was ***~~already~~*** ashore.

### Notes
Check the tide tables: would a ferry really leave at dawn in March?

Who kept the mother's letter all these years? Decide before scene 3.

Mara should notice the blue house before she reaches it.

### Comments
- c2 | red | 2026-10-31T20:38:00-07:00 | c0-22 | "The ferry left at dawn" | Check the ferry schedule for the 1950s.
- c1 | purple | 2026-10-31T20:40:00-07:00 | c332-338 | "letter" | Too early for this reveal?
- c4 | green | 2026-11-01T09:15:00-08:00 | c15-115 | "at dawn, and Mara watched the harbor lights go out one by one behind her.\nShe had packed in the dark" |
- c5 | blue | 2026-11-01T09:20:00-08:00 | c236-254, c272-283 | "the engine coughed", "swore at it" | Too much | "noise" here?
- c7 | gray | 2026-11-01T10:02:00-08:00 | notes c160-170 | "blue house" | Plant this in Arrival.
- c6 | pink | 2026-10-29T18:00:00-07:00 | detached | Cut the dream sequence?

### Marks
- color purple | c45-58 | "harbor lights"
- highlight blue | c259-277 | "the deckhand swore"
- highlight green | notes c10-21 | "tide tables"
- color red | notes c114-136 | "Decide before scene 3."

## Arrival
id: 01JC3E28JT97KB6CQ643DZVMXX
modified: 2026-11-02T03:18:00-08:00
tags: Mara, island

Nobody met her at the landing, which she had half expected and wholly dreaded.

The road up from the quay was the same road, narrower than in memory, and the gulls were louder.

At the top of the hill she stopped to catch her breath and saw that the house had been painted blue.

\#7 was painted on the gate, and under it someone had chalked \*KEEP OUT\*.

<br>

\- Hello? she called, to the gate, to the gulls, to no one.\␠

A tin sign read ROOM\_2 \~ C:\\ATTIC.

### Notes
Arrival should feel like the opposite of the ferry: loud, bright, nobody waiting.

### Comments
- c3 | blue | 2026-11-01T10:12:00-08:00 | c263-275 | "painted blue" | Blue house: set this up earlier?

## The letter
id: 01JCQKFBF5KZNWJ47TAN9ZT24M
modified: 2026-11-01T15:36:00-08:00
tags: mother, clue, letters\, unsent

He read it twice before he understood that the handwriting was his mother's.

It had been folded and unfolded so many times that the creases had gone soft as cloth.

There was no date, only the name of the island and a sentence he would spend the winter trying to forget.

### Unparsed
- [comments] - c9 | purpel | 2026-11-01T15:30:00-08:00 | c17-23 | "before" | Too slow?
- [metadata] mood: grim

# Boneyard

## The brother's boat
id: 01JCY1JX4WHRDD459GQ8H7QEZZ
modified: 2026-07-09T13:00:00-07:00

Pieter had painted the boat the same blue as the house, which nobody mentioned.

The rest of this scene is placeholder text for the mockup, double-spaced and indented as it would be on the manuscript page.

Edit anything here: the page is a live editor, and the formatting bar, comments and read-aloud button all work on it.

### Comments
- c1 | gray | 2026-07-09T12:40:00-07:00 | c28-54 | "the same blue as the house" | Same blue as the house: too neat?
```

(`\␠` stands for a backslash followed by a real space at the end of that line. If an editor strips the space, §1.3
reads the line the same way.)

What it parses to, in the places that exercise a rule:

| Where | Parsed as |
| --- | --- |
| Book | Title `My Novel`; error entries: `[front matter] author: S. Basu` |
| *The ferry*, paragraph 2 | `She had packed in the dark, ` · *`by feel`* · `, the way … when ` · **`the house was asleep and `** · ***`leaving`*** · *` still seemed like a game.`* |
| *The ferry*, paragraph 3 | … `by then she was ` · bold+italic+strike `already` · ` ashore.` |
| *The ferry*, body plain text | 405 characters. `c4` covers the end of paragraph 1 and the start of paragraph 2 (the `\n` between them carries nothing); it overlaps `c2` (`at dawn`) and the purple mark (`harbor lights`). `c5` covers two separate stretches, and the blue highlight `the deckhand swore` overlaps its second one. |
| *The ferry*, comments | `c2`, `c1`, `c4` (text empty), `c5` (text `Too much | "noise" here?`), `c7` (notes), `c6` (detached) |
| *Arrival*, paragraphs 4–7 | `#7 was painted on the gate, and under it someone had chalked *KEEP OUT*.` · *(empty paragraph)* · `- Hello? she called, to the gate, to the gulls, to no one.␠` · `A tin sign read ROOM_2 ~ C:\ATTIC.` |
| *Arrival*, body plain text | 445 characters; the empty paragraph makes `…*KEEP OUT*.\n\n- Hello?…` |
| *The letter*, tags | `mother`, `clue`, `letters, unsent` |
| *The letter*, error entries | `[comments]` (reason: E4, unknown palette name `purpel`); `[metadata]` (reason: unknown key `mood`) |
| *The brother's boat* | In the Boneyard; one comment, `c1` |

Serializing that parse gives the file above byte for byte, with the three error entries it started with and no new
ones: it is in canonical form.

### 9.2 A damaged book

A writer's editor saved the file with `\r\n` endings and hard-wrapped a paragraph; they pasted an emoji and a sentence
from a Windows-1252 document; they typed a scene heading and a mistyped notes heading into the middle of *Arrival*,
copied *The ferry*'s id into *The letter*, removed *Arrival*'s id, mistyped a palette name, and the file was cut off
in the middle of the last line. (`⟨93⟩` and `⟨94⟩` are single bytes 0x93 and 0x94: Windows-1252 curly quotes, invalid
as UTF-8.)

```markdown
---
title: My Novel
format: 2
colour: blue
---

Remember to back this up!

## The ferry
id: 01JCM9S346Q3D25VT4F5V37E3S
modified: 2026-11-02T09:00:00-08:00
tags: opening, Mara

The ferry left at dawn, and Mara watched the
harbor lights go out one by one behind her.

“Wait,” she said. 🌊

### Comments
- c2 | red | 2026-10-31T20:38:00-07:00 | c0-22 | "The ferry left at dawn" | Check the ferry schedule.
- c1 | mauve | 2026-10-31T20:40:00-07:00 | c45-58 | "harbor lights" | Too pretty?
- c3 | blue | 2026-10-31T20:41:00-07:00 | c4-9 | "ferry left" | Wrong range.

## Arrival
modified: 2026-11-02T03:18:00-08:00

Nobody met her at the landing.

## Interlude

The gulls were louder than she remembered.

### Note
Gulls: check species.

## The letter
id: 01JCM9S346Q3D25VT4F5V37E3S
modified: 2026-11-01T15:36:00-08:00

He read it twice before he understood ⟨93⟩mother⟨94⟩

### Comments
- c1 | purple | 2026-11-01T15:30:00-08:00 | c3-7 | "read
```

The parse (with `<id A>`, `<id B>`, `<id C>` from the id generator and `<now>` the time it was opened):

| Scene | Title, id, modified | Text | Comments | Error entries |
| --- | --- | --- | --- | --- |
| *(book)* | `My Novel` | — | — | `[front matter] colour: blue` · `[line] Remember to back this up!` · `[notice] Some of this file wasn't valid UTF-8: 2 byte(s) were read as Windows-1252 characters.` |
| 1 | *The ferry*, `01JCM9S346Q3D25VT4F5V37E3S`, as written | ¶1 `The ferry left at dawn, and Mara watched the harbor lights go out one by one behind her.` (wrapped lines joined) · ¶2 `"Wait," she said. [?]` (curly quotes spelled in ASCII) | `c2` | `[comments] - c1 | mauve | …` (E4) · `[comments] - c3 | blue | … | c4-9 | "ferry left" | Wrong range.` (E9: `c4-9` is `ferry`) · `[notice] Characters with no ASCII form were replaced with [?]: U+1F30A.` |
| 2 | *Arrival*, `<id A>`, as written | `Nobody met her at the landing.` | — | `[notice] This scene had no id, so it was given <id A>.` |
| 3 | *Interlude*, `<id B>`, `<now>` | ¶1 `The gulls were louder than she remembered.` · ¶2 `Gulls: check species.` (still body: the unknown heading didn't change the section) | — | `[line] ### Note` · `[notice] This scene had no id, so it was given <id B>.` · `[notice] This scene had no modified date, so it was set to <now>.` |
| 4 | *The letter*, `<id C>`, as written | `He read it twice before he understood "mother"` (bytes 0x93/0x94 → “ ” → `"`) | — | `[comments] - c1 | purple | 2026-11-01T15:30:00-08:00 | c3-7 | "read` (E8, unterminated) · `[notice] This scene's id 01JCM9S346Q3D25VT4F5V37E3S was already used by an earlier scene, so it was given <id C>.` |

The writer sees twelve rows in the Errors tab. The page shows every word they wrote. The next save writes clean UTF-8
with `\n` endings, the joined paragraph, `"` for the curly quotes, `[?]` for the emoji, and the twelve entries in
`### Unparsed` sections: the book's after the front matter, the others at the end of their scenes.

---

## 10. Decisions on the open questions

ADR 0022 settles the format's shape; these were the gaps this spec had to fill. **The owner accepted every recommendation
below on 2026-11-02** (Q1, Q4 and Q13 were considered individually), so † rules are now as binding as the ADR's. Notice wording
(Q5) is still to be approved when the Errors tab is built.

The demo book's assumptions (end-exclusive ranges over the body's plain text with paragraphs joined by `\n`; comment
fields `id | color | created | range | "quote" | text`; mark fields `color|highlight <name> | [notes ]range | "quote"`;
metadata keys `id`/`modified`/`tags`; no escaping in its text) are **all kept**: the demo file is valid, canonical
v2 as written. This spec only adds forms the demo doesn't use: range and quote **lists** (Q4), the `detached` form
(Q4), escapes, `<br>` (Q1), and Unparsed entries.

| # | Question | Decision |
| --- | --- | --- |
| Q1 | **Empty paragraphs.** The model allows them and they count in offsets, but blank lines can't express them. Write them as `<br>` (renders as a blank line in Markdown viewers), or drop them on save? | `<br>`. Dropping them would silently change the writer's text and shift every later offset. |
| Q2 | **Invalid UTF-8: Latin-1 or Windows-1252?** ADR 0022 says "decoded as their Latin-1 characters" but also that "an editor that saved … Windows-1252 loses nothing". Under Latin-1, bytes 0x80–0x9F (1252's curly quotes, dashes, €) are control characters and would become `[?]`. | Decode as Windows-1252, so the transliteration table (§1.2) then spells 1252's typographic characters in ASCII, as it does pasted ones. Bytes 0xA0–0xFF are identical either way. |
| Q3 | **Tabs.** ADR 0022's rule would make every tab `[?]` plus a notice; writers often indent paragraphs with tabs. | Read a tab as a space. Indentation is insignificant (§1.3), so tab-indented paragraphs just work. |
| Q4 | **Non-contiguous comments and detached comments.** Typing inside a commented passage leaves its anchor in pieces, and PLAN §8.1 keeps comments whose text is gone. | Range and quote lists (`c1-4, c9-12 | "abc", "def"`) and a `detached` range field with no quote, as in §4.2–§4.5. |
| Q5 | **Notices.** Repairs with nothing verbatim to keep (a fresh id, `[?]`, the encoding fallback) are stored as `[notice]` entries until dismissed. Is persisting them right, and is the wording (§5.3) acceptable? It's on-screen text. | Persist them: ADR 0022 says error entries stay until cleared, and a writer who opens the book a day later should still learn their emoji became `[?]`. Wording to be agreed. |
| Q6 | **"Zero error entries" in save verification.** Taken literally, a book with a preserved Unparsed entry could never be saved. | Read it as "no *new* entries": the parsed entries must equal the book's own (§7.2). |
| Q7 | **A newer format (`format: 3`).** | Parse best-effort as v2 with a notice, and **open the book read-only** (ADR 0020's read-only state) so this version can't save a downgraded copy over it. |
| Q8 | **Defaults.** Missing title → `Untitled`; missing `modified` → the time the book was opened; missing id → a fresh ULID. | As stated. The parser takes the clock and id generator as inputs. |
| Q9 | **`tags` when empty.** ADR 0022 says a missing key yields an error entry; the demo omits `tags:` when there are none. | Make `tags` optional: omitted when empty, absent means none, no notice. `id` and `modified` stay required. |
| Q10 | **Unknown `###` headings.** Should the text after `### Note` (typo) stay where it was, or become error entries? | Keep it in the current section (it stays visible and editable); only the heading line becomes a `[line]` entry. |
| Q11 | **Conflicting color marks** (two overlapping `color` marks with different names, which Scene It never writes). | The later line wins, silently. |
| Q12 | **Where index errors show.** `Archive/index.md` can hold error entries, but the Errors tab is per book. | Add a "File Cabinet" group to the Errors tab, listing the index's entries. |
| Q13 | **Inline markup rules.** This spec uses simple toggles plus two hand-editing safeguards (free-standing delimiters and unbalanced delimiters are text), not CommonMark's flanking rules. The cost: `2*3*4` typed by hand reads as italic `3`. | Keep the toggles. They're short to specify, make any overlap of styles expressible, and Scene It escapes every literal `*` when it saves. |
| Q14 | **Formatting in a hand-written title** (`## The *ferry*`). | Drop it silently, keeping the text, as ADR 0015 does for formatted titles. |
| Q15 | **More typographic substitutions?** ADR 0022's table omits „ ‚ (low quotes), ′ ″ (primes), − (minus) and the non-breaking hyphen, which become `[?]`. | Keep the ADR's table for now; extend it later, in the one table shared by the editor and the parser. |
