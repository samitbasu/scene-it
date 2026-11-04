# Scene It review formats: the review copy, `<name>.review.md`, and Copy/Save Review

**Status:** Draft (issue #78), revised with the owner's decisions on its questions (2026-11-03, §9). Implements [ADR 0029](../decisions/0029-review-round-trip.md),
which is binding. It builds on the [book format](book-format.md), whose lexical rules, entries, Unparsed sections,
never-fail rule and canonical form it **reuses by reference**. Where this document doesn't restate a rule, the book
format's rule applies unchanged.

It covers four things:

1. **The review copy** (§2): the single `.md` file **Export as SceneIt…** writes, and how Scene It recognises it.
2. **The review file** `<name>.review.md` (§3–§4): the reviewer's comments and notes, kept beside the copy, and how it
   finds its copy.
3. **Copy Review** (§5–§6): the HTML and plain text put on the clipboard.
4. **Save Review…** (§7): the standalone `.html` file with working checkboxes.

§8 is a complete worked example, §9 the owner's decisions, and the appendix holds corpus-style test cases.

**Conventions.** Those of the book format (its "Conventions" box): **†** marks a rule this document adds, and every †
rule here was decided by the owner (§9). `␠` is a space, `⏎` the end of a line. "Book format §n" refers
to [book-format.md](book-format.md). Text is **strict ASCII** ([ADR 0028](../decisions/0028-strict-ascii-no-input-methods.md)):
both files are read through the book format's §1.2 pipeline as ADR 0028 amends it (issue #74), so after reading, one
character is one byte and offsets count bytes. The outputs of §5–§7 are the only place non-ASCII characters appear
(curly quotes, dashes, `☐`), and the HTML spells them as character references, so it's ASCII too.

---

## Contents

1. [The files at a glance](#1-the-files-at-a-glance)
2. [The review copy](#2-the-review-copy)
3. [The review file (`<name>.review.md`)](#3-the-review-file-namereviewmd)
4. [How a review finds its copy](#4-how-a-review-finds-its-copy)
5. [Copy Review: content, quoted paragraphs and typography](#5-copy-review-content-quoted-paragraphs-and-typography)
6. [Copy Review: the HTML and plain-text layouts](#6-copy-review-the-html-and-plain-text-layouts)
7. [Save Review…: the standalone `.html`](#7-save-review-the-standalone-html)
8. [Worked example](#8-worked-example)
9. [Decisions](#9-decisions)
- [Appendix: corpus-style cases](#appendix-corpus-style-cases)

---

## 1. The files at a glance

| File | Written by | Holds | Ever rewritten? |
| --- | --- | --- | --- |
| `My Novel.md`, the **review copy** | The author's Scene It (Export as SceneIt…) | The chosen scenes' titles, ids and text, with bold, italic and strikethrough | **Never** after export. The reviewer's Scene It only reads it. |
| `My Novel.review.md`, the **review file** | The reviewer's Scene It (autosave) | The reviewer's comments (anchored to the copy's text) and notes | On every autosave, with the book's safe-save rules |
| Clipboard HTML + plain text | Copy Review | Per scene: ☐ comment items, each quoting the passage's paragraph with the passage marked, then notes | — |
| `My Novel review.html` | Save Review… | The same content, with real checkboxes | — |

The copy and the review file are both tolerant Markdown in the book format's dialect. The copy **is** a book-format
file (format 2) with two extra front-matter keys; the review file is a small grammar of its own (format 1) built from
the book format's parts.

---

## 2. The review copy

### 2.1 The marker

A review copy is a book-format file whose front matter has an **`export`** key †:

```
---
title: My Novel
format: 2
export: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
exported: 2026-11-03T10:15:00-08:00
---
```

| Key | Value | Meaning |
| --- | --- | --- |
| `title` | As book format §1.5 | The author's book title, as it was at export |
| `format` | `2` | The book format version. The copy follows it exactly. |
| `export` † | An id: 1–64 characters from `A–Z a–z 0–9 _ -` (book format §2.2). Scene It writes a fresh 26-character ULID for **every export**. | The **export id**. It's what the copy is recognised by, and what its review file binds to (§4). Two exports of the same book, even of the same scenes a minute apart, have different export ids. |
| `exported` † | A timestamp (book format §2.2's `modified` format) | When the copy was exported. Informational only: shown when a review file belongs to another copy (§4.3). |

**Written as:** `---⏎title: <title>⏎format: 2⏎export: <id>⏎exported: <timestamp>⏎---⏎`. The book format's canonical
front matter, with the two keys added after `format`.

### 2.2 What it contains

The copy is the **projection** of the author's book onto the scenes they ticked:

- **Book:** the title. No book-level Unparsed entries.
- **Story scenes:** the ticked ones only, in story order. Each keeps its `## <title>`, its **`id`** and its
  **`modified`** (§9 Q2), and its body paragraphs with **bold, italic and strikethrough only**. Colors, highlights and
  comment underlines are removed, and the runs that then have the same styles merge.
- **Nothing else:** no tags, notes, comments, marks, Unparsed entries or Boneyard (ADR 0029: they're the author's
  private working material).

It's written by the book serializer (book format §7.1), so it's canonical, and it's verified exactly as a save is
(book format §7.2), parsing in review-copy mode (§2.4): the parse must be the projected book, with no error entries
and the same bytes. If verification fails, nothing is written. The file is written atomically to where the author
chose; it isn't inside a package and isn't backed up.

### 2.3 Recognising files on Review Book…

Review Book… accepts a `.md` file and looks at its front matter (book format §1.5) to decide what it is †:

| Front matter has | It is | Review Book… |
| --- | --- | --- |
| A valid `export` | A review copy | Opens it for review (§4.1 finds its review file) |
| No `export`, but a valid `copy` | A review file (§3) | Opens the copy it belongs to (§4.4), and this review |
| Neither | Something else, e.g. a book's `book.md` | Refuses, with an alert saying it isn't a review copy (§9 Q3). Nothing is written. |
| `format` newer than 2 (in a copy) | A copy from a newer Scene It | Refuses, asking the reviewer to update Scene It (§9 Q4) |

Books are packages and open with Open; a review copy never opens as a book. If someone does put a review copy into a
package as its `book.md`, the **book** parser treats `export` and `exported` as unknown keys (`[front matter]` entries,
book format §1.5), so that book opens repaired and read-only (ADR 0024). The book format itself doesn't change.

### 2.4 Reading a copy (review-copy mode)

The copy is parsed by the book parser, with these differences †:

1. **Front matter:** `export` and `exported` are known keys. A bad `exported` value is a `[front matter]` entry, as
   in book format §1.5; a missing one is silent.
2. **Fresh scene ids are positional, not random.** A scene whose id is missing, bad or a duplicate gets
   `scene-<N>`, where `N` is its 1-based position among the file's `##` sections. If the file already uses that id,
   `-2`, `-3`, … is appended until it's free. The notice is book format §5.3's, naming the new id. The copy is
   never rewritten, so the id must be the same at every open, or the review's scene keys (§3.3) would stop matching.
3. Everything else is the book format, never-fail included: every byte sequence parses to a book.

What the reviewer sees and comments on is the parse's **story scenes**: their titles and body text, with styles. If a
copy carries anything a real export never writes (notes, comments, marks, tags, a Boneyard), it's ignored, and
Boneyard scenes can't be commented on. The copy's error entries (damage in transit, for example) are listed in the
Errors tab, view-only: the copy is never written, so they can't be deleted or repaired, and they don't stop the review.

**The received text** is this parse. Every anchor in the review file (§3.5) is a range and quote into a story scene's
**body plain text** as book format §3.6 defines it, computed from this parse. So the review is consistent with exactly
what the reviewer saw, even if the copy was damaged on the way (a mail client wrapping lines or converting line
endings doesn't change the parse at all: book format §1.2, §3.1).

---

## 3. The review file (`<name>.review.md`)

### 3.1 At a glance

```markdown
---
title: My Novel
format: 1
copy: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
id: 01JDD8WQ4K7M2N9P3R5S6T8V0X
---

### Notes
Overall: I couldn't put it down.

## The ferry
id: 01JCM9S346Q3D25VT4F5V37E3S

### Notes
Strong opening.

### Comments
- c1 | red | 2026-11-04T09:12:00-08:00 | c45-58 | "harbor lights" | Too pretty for Mara's mood?
- c2 | gray | 2026-11-04T09:30:00-08:00 | detached | The deckhand's line feels like a cliche.
```

In order, the file holds:

| Part | Required? | Written when |
| --- | --- | --- |
| Front matter (§3.2) | Expected; defaults apply if missing | Always |
| General notes, `### Notes` (§3.3) † | No | The review has general notes (§9 Q5) |
| Review-level `### Unparsed` (§3.7) | No | The review has review-level error entries |
| Scene sections, each a `## ` heading (§3.4) | No | One per copy scene that has notes, comments or error entries, in the copy's story order |

The lexical layer is the book format's, unchanged: §1.2 (bytes to characters), §1.3 (lines and trimming), §1.4
(heading shapes), §3 (paragraphs and inline markup), §4.1 (entries and field escapes), §4.2–§4.5 (ranges, quotes,
comment entries, detached comments) and §5 (Unparsed entries). What differs is which headings and keys mean what.

### 3.2 Front matter

Read as book format §1.5 (opening and closing `---`, `key: value` lines, case-insensitive keys, first occurrence
wins, unknown or duplicate keys are `[front matter]` entries).

| Key | Value | Missing (or bad) |
| --- | --- | --- |
| `title` | Plain text | Ignored when read, silently. It's written from the copy's title, for anyone reading the file in an editor; the copy's title is the one that counts. |
| `format` | A decimal integer, read as book format §1.5 reads it; the current review format is **1** | Missing: read as 1, plus a notice. Not 1: read as 1, plus a notice; **newer than 1 opens read-only** with no way to make it editable, as ADR 0024 does for books. Not an integer: a `[front matter]` entry, then missing. |
| `copy` † | An id (book format §2.2's character set): the **export id** of the copy this reviews | A notice; the review is taken to be the review of the copy it was opened with (§4.1 step 3), and the next save writes that copy's export id. Bad: a `[front matter]` entry, then the same. |
| `id` † | An id: the **review id**, a ULID made when the review file is created. It keys the standalone page's ticks (§7.3), so two reviewers of one copy never share them. | A fresh ULID, plus a notice. |

Reviews are **anonymous** (§9 Q10): there's no key for the reviewer's name, so a `reviewer:` line typed by hand is an
unknown key, a `[front matter]` entry, like any other.

**Written as:** `---⏎title: <title>⏎format: 1⏎copy: <export id>⏎id: <review id>⏎---⏎`. The title is field-escaped as
book format §1.5 escapes it.

### 3.3 The preamble: general notes †

Between the front matter and the first `##` heading, two subsections are legal, in any order and repeatable:

- `### Notes`: the review's **general notes**, paragraphs exactly as a scene's notes (book format §3).
- `### Unparsed`: review-level error entries (book format §5).

Anything else there (prose before any subsection, a `### Comments`, an unknown heading) is a review-level `[line]`
entry, as book format §1.6 treats a book's preamble.

### 3.4 Scene sections

A scene section holds the reviewer's work on one scene of the copy. It's **keyed by the scene's id**; the title is a
convenience copy.

| Rule | Detail |
| --- | --- |
| Heading | A `##` heading-shaped line (book format §2.1) starts a section. Its title text is **ignored when read** † and written from the copy's scene title, escaped as book format §2.1 writes titles. A reviewer who retitles a section in an editor loses only the retitling. |
| Metadata | The `key: value` lines directly under the heading (book format §2.2's extent rule). The only key is **`id`**, the copy scene's id. Any other key (`modified`, `tags`) is a `[metadata]` entry of the section, as book format §2.2 treats an unknown key. |
| Body | A section has no body. Each non-blank line between the metadata and the first subsection heading is a `[line]` entry of the section †. |
| Subsections | `### Notes` (the reviewer's notes on this scene: paragraphs, book format §3), `### Comments` (comment entries, §3.5) and `### Unparsed` (entries, book format §5). Read in any order and repeatable, as book format §2.4. |
| Not understood | `### Marks` and any other heading-shaped line: a `[line]` entry, and the current section doesn't change (book format §1.4). A review has no marks: the reviewer's notes have bold, italic and strikethrough but no colors or highlights. |
| Same id twice | Two sections with the same id are **one scene** †: their notes, comments and entries are appended in file order, and the next save writes one section. Comment ids must still be unique across them (a repeat is E3). |
| Section order | Any. Sections are written in the copy's story order. |

**Orphan sections** †. A section whose id is missing or bad, or names no story scene of the copy, can't be anchored to
anything. Its lines are kept, never lost: **every non-blank line of the section**, from its `##` heading up to the
next `##` heading or the end of the file, becomes a review-level `[line]` entry, verbatim after trimming, in file
order, followed by one notice:

| Situation | Notice payload (wording to be agreed, §9 Q12) |
| --- | --- |
| No valid id | `A scene section had no id, so its lines were kept as entries.` |
| Id not in the copy | `There's no scene with id <id> in this review copy, so that section's lines were kept as entries.` |

The reviewer sees them in the Errors tab, where they can copy the text out. They're never re-parsed (book format
§5.1); orphans don't happen through the app (§4 binds each review to one copy, whose ids never change), only through
hand-editing or a damaged file. See §9 Q8.

### 3.5 Comments

A comment entry is exactly book format §4.4, in all its forms, including range and quote lists and the `detached` form
(§4.5):

```
- <id> | <color> | <created> | <ranges> | <quotes> | <text>
- <id> | <color> | <created> | detached | <text>
```

The one difference is **what the ranges address**: the **body plain text of the copy scene the section is keyed to**,
as the copy parses (§2.4), not anything in the review file. So:

- A range is valid against that text by book format §4.2's rule, and its quote must equal that text at the range
  (§4.3). A mismatch is E9, a `[comments]` entry, exactly as in a book. This is what protects a review if its copy is
  swapped for a different one: no comment can silently point at the wrong words.
- **A `notes` range is always E7** †: the copy's scenes have no notes text a reviewer could see (§2.4), so the
  addressed plain text is empty.
- Errors are book format §4.8's E1–E10, tagged `[comments]`.

**Detached comments in a review** are **comments on the scene as a whole** †: the text a review points at never
changes, so the only way to make one is deliberately (in the app, Comment on Scene, §9 Q6; or by hand). They become ☐
items with no passage (§5.1).

Colors are any of the seven palette names (book format §4.6). They're kept for the reviewer's own sorting, and don't
appear in Copy Review's output (§9 Q7).

### 3.6 Notes

The general notes and each scene's notes are paragraphs exactly as book format §3 defines them: wrapped lines joined,
`<br>` for an empty paragraph, bold, italic and strikethrough as toggles, the same escapes. A review has no marks, so
notes carry no colors or highlights, and the review's notes editor offers only bold, italic and strikethrough.

### 3.7 Unparsed entries and notices

Book format §5, unchanged: the six tags, `- [<tag>] <payload>`, payloads never re-parsed, entries kept until the
reviewer deletes or repairs them in the Errors tab. Review-level entries are written in the preamble's `### Unparsed`;
a scene section's entries in its own. Order (book format §5.2):

1. **Review level:** entries in file order of the lines that produced them (front matter, preamble lines, preamble
   `### Unparsed` entries, and each orphan section's lines followed by its notice); then the review's own notices in
   the order encoding, format, copy, id, replaced or transliterated characters.
2. **A scene:** entries in file order; then notices for characters replaced in that section.

The notices the review format adds (wording to be agreed, §9 Q12):

| Situation | Payload |
| --- | --- |
| No `format` | `The file had no format line; it was read as format 1.` |
| `format` not 1 | `The file says format <n>; this version of Scene It reads review format 1.` |
| No (valid) `copy` | `This review had no copy line, so it was taken to be the review of this copy, <export id>.` |
| No (valid) `id` | `This review had no id, so it was given <review id>.` |
| An orphan section | §3.4 |

The reasons the Errors tab derives (book format §5.4; the corpus's `entries.txt` reasons) are the book's: E1–E10,
`not-a-field`, `unknown-key`, `repeated-key`, `bad-id`, `bad-date`, `bad-format`, `other-format`, `line`, `notice`,
`reads-now`.

### 3.8 The parser never fails

`parse(bytes, copy) → Review` is **total**: every byte sequence parses to a review against every copy. Damage costs
what it touches, at most the scene section it's in, never the review. A damaged review file opens **read-only**,
exactly as ADR 0024 opens a damaged book: new error entries make it `.repairedOnOpen`, and Make Editable keeps the
original bytes first (§9 Q9 for where). Entries already in `### Unparsed` don't count.

What's different from a book's damage table (book format §6), everything else being the same:

| Damage | Result |
| --- | --- |
| **Empty file** | A review with no notes or comments; notices: no format, no copy, no id. |
| **A section's `id:` line damaged or deleted** | An orphan (§3.4): its lines become review-level `[line]` entries, plus a notice. Nothing is lost; the notes and comments in it no longer apply until the reviewer fixes the file. |
| **A section's `##` line damaged** | Its lines join the previous section: under `### Notes` they're notes text; under `### Comments` they're E1 or E2 entries; before any subsection, `[line]` entries. |
| **A comment whose quote doesn't match the copy** (the copy was hand-edited, or replaced by another file with the same export id) | E9, a `[comments]` entry; that comment drops out of the review and of Copy Review until it's fixed. |
| **Body text under a section heading** | `[line]` entries of that section. |
| **`### Marks`** | A `[line]` entry; its entries are then read in whatever section was current (usually failing as comments, E2). |
| **`format: 2`** (a newer review format) | Read as 1, a notice, read-only. |

### 3.9 Canonical form and save verification

**The canonical form** †, written by `serialize(review, copy)`: UTF-8 (ASCII), `\n` endings, blocks joined by one
blank line, one final `\n`, as book format §1.7. The blocks, in order:

1. The front matter (§3.2).
2. The general notes, if any: notes paragraph blocks, the first starting with the line `### Notes` (as book format
   §1.7 writes a scene's notes).
3. The review-level Unparsed block, if any.
4. For each **story scene of the copy, in story order**, that has notes, comments or error entries in the review:
   - the header `## <copy title>⏎id: <id>`;
   - its notes paragraph blocks (the first starting `### Notes`);
   - `### Comments` and its entries, in model order, written as book format §4.4 writes them;
   - `### Unparsed` and its entries.

A scene with nothing in it isn't written; one with only notes has no Comments block, and so on.

**Accepted, and canonicalized silently on the next save** (in addition to book format §7.3's table):

| Input | Canonical |
| --- | --- |
| A section title that differs from the copy's | The copy's title |
| Sections in any order; two sections for one scene; a section with nothing in it | Story order; one; omitted |
| Front-matter keys in another order; a `title` that differs from the copy's | `title`, `format`, `copy`, `id`; the copy's title |

**Save verification** is book format §7.2 with the copy as context: let `b = serialize(review, copy)` and
`p = parse(b, copy)`. The save may proceed only if `p`'s error entries are exactly the review's, `p` is the review
(neighbouring runs of the same format merged), and `serialize(p, copy) == b` byte for byte. The autosave, rotation and
lock rules are the book's (ADR 0005, 0020, 0029); their placement for a file outside a package is §9 Q9.

---

## 4. How a review finds its copy

### 4.1 Opening a copy

**The export id binds a review to its copy; the file name is only a convention.** When Review Book… opens a copy
`D/X.md` (§2.3) †:

1. **Candidates** are the files in `D` whose names end in `.review.md` (case-insensitive). Scene It reads each one's
   front matter.
2. **A match** is a candidate whose `copy` equals the copy's `export`. If there are matches, the review is
   `X.review.md` if it's one of them, otherwise the most recently modified match. (Several matches only happen if the
   reviewer duplicated a review file.)
3. **Otherwise**, if `X.review.md` exists and has **no valid `copy` line** (its front matter is damaged), it's taken
   to be this copy's review. It parses with the "no copy" notice and opens read-only (§3.8), so the reviewer sees
   their comments, and nothing is lost by guessing wrong: Make Editable keeps the original.
4. **Otherwise** this is a new review. Nothing is written until the reviewer's first comment or note; then the review
   file is created as `X.review.md`, or, if that name is taken (by the review of a different copy, §4.3), as
   `X-2.review.md`, `X-3.review.md`, …: the first free name. Its review id is made then.

Reopening the copy finds the same review file by step 2, so the review resumes.

### 4.2 Renaming files

| The reviewer | What happens |
| --- | --- |
| Renames the copy (`X.md` → `Y.md`) | Opening `Y.md` finds `X.review.md` by its `copy` id (step 2) and resumes. Scene It keeps writing to `X.review.md`; it never renames files. |
| Renames the review, keeping `.review.md` (`X.review.md` → `Jo.review.md`) | Found by step 2. |
| Renames the review to something else (`X.review.md` → `notes.md`), or moves it to another folder | Not a candidate, so opening the copy starts a new review. The renamed file is untouched, and opening it directly with Review Book… (§4.4) resumes it. |
| Moves both to another folder together | Found as before. |

### 4.3 A different copy with the same name

The reviewer receives a second export of the book and saves it over the first as `X.md`. `X.review.md` now holds a
review of a copy that's gone (a different export id). It's **never overwritten**: by §4.1 step 4 the new review goes
in `X-2.review.md`. When this happens, Scene It says so once, at open: `X.review.md` is a review of a different copy
(exported on the old copy's `exported` date, if the old review can tell; otherwise just "a different copy"), so this
review will be saved separately. Wording to be agreed (§9 Q12).

The old review's comments can't be carried over: their ranges point into text that no longer exists, and there's no
re-anchoring (ADR 0022).

### 4.4 Opening a review file directly

Review Book… on a review file `D/Y.review.md` (recognised by its `copy` key, §2.3) looks for its copy among the
`.md` files in `D` that aren't review files: the one whose `export` equals the review's `copy`, preferring `Y.md`
(the name without `.review`). If it's found, the copy opens **with this review**, even if §4.1 would have picked
another match. If not, an alert says the copy it belongs to must be in the same folder; nothing opens.

---

## 5. Copy Review: content, quoted paragraphs and typography

Copy Review, Save Review… and the plain text all render one **report**, built once from the review and its copy,
and then written three ways (§6, §7). That keeps them from disagreeing.

### 5.1 What the report contains, in order

1. **The header:** the copy's book title and the date Copy Review was chosen, in the local time zone. Reviews are
   anonymous: the report never names the reviewer (§9 Q10).
2. **General notes**, if any (§3.3).
3. **Each scene**, in the copy's story order, that has at least one comment or a note. Scenes with neither are left
   out. For each:
   1. its **title** (an empty title is shown as `(untitled scene)`);
   2. its **comments as ☐ items**: anchored comments ordered by the start of their first range, then by the end of
      their last, then model order; then detached comments in model order. An anchored item is its quoted
      paragraph with the passage marked (§5.2), then the comment's text. A detached item is the comment's text alone. A comment with
      empty text shows only its passage;
   3. its **notes**, if any.

Error entries are never included. The report holds no manuscript text beyond the paragraphs its comments quote
(§5.2). Copy Review is disabled when the report would have no general notes and no scene.

### 5.2 The quoted paragraph

An anchored item quotes **the whole paragraph** the passage is in, with the passage marked (§9 Q11). There's no sentence rule, no character cap and no ellipsis.

For an anchored comment, let `T` be the copy scene's body plain text (book format §3.6) and `[s, e)` the **hull** of
the comment's ranges: `s` the smallest start, `e` the largest end. (A review's comments normally have one range; the
text between ranges of a hand-made list is marked as passage too.)

- **The quoted text** is `T[ps ..< pe]`: `ps` is the index just after the last `\n` before `s` (or 0), and `pe` is the
  index of the first `\n` at or after `e` (or the length of `T`). So it's the paragraph holding the passage, or, for a
  passage that spans paragraphs, every paragraph from the first it touches to the last.
- It's shown in three pieces: **before** `T[ps ..< s]`, the **passage** `T[s ..< e]`, and **after** `T[e ..< pe]`.
  Either outer piece may be empty.
- **How the passage is marked:** in HTML, the passage is in a span with a yellow background and the before and after
  pieces in gray spans (§6.2); in plain text, the passage is enclosed in square brackets, `[` and `]` (§6.3).
- A `\n` inside the quoted text (a passage spanning paragraphs) is shown as ` ¶ ` (space, U+00B6, space).
- Styles (bold, italic, strikethrough) are the copy's, character by character, in all three pieces.
- **Several comments on one paragraph each quote it in full**, each with its own passage marked: every item stands on
  its own, so the author can tick them off one by one.

The output therefore holds no manuscript text outside the paragraphs that have comments. Examples are in the appendix
(C2).

### 5.3 Typographic smartening †

ADR 0029: the output's typography is smartened. Everything stored is ASCII (ADR 0028), so this runs on output only,
over each **unit**: the book title, a scene title, a body paragraph (before it's split into pieces), a comment's
text, a notes paragraph.

**Quotes are decided on the whole unit**, left to right, so a quote's direction doesn't depend on where the passage
starts or ends. For the character at `i`, `prev` is `T[i−1]` (none at the start) and `next` is `T[i+1]` (none at the end); a `\n`
counts as a space. Call `i` an **opening position** if `prev` is none, a space, `(`, `[`, `{`, `-` or `/`, or a quote
already made opening (`“` or `‘`), **and** `next` exists and isn't a space.

| Character | Becomes |
| --- | --- |
| `"` | `“` (U+201C) at an opening position; otherwise `”` (U+201D) |
| `'` between two ASCII letters or digits | `’` (U+2019): `don't`, `Mara's` |
| `'` at an opening position, followed by a digit, or by one of `em` `tis` `twas` `til` `cause` `n` (case-insensitive) and then a non-letter or the end | `’`: `'90s`, `'Tis`, `rock 'n' roll` |
| `'` at any other opening position | `‘` (U+2018) |
| `'` anywhere else | `’` |

**Dashes and ellipses are replaced within each piece** of the output (the before, passage and after pieces of a
quoted paragraph, §5.2, or a whole unit when it isn't split), and within each run of one style in it:

| Run of characters | Becomes |
| --- | --- |
| Exactly two `-` | `—` (U+2014). One `-` stays; three or more stay as they are (`----` is not a dash). |
| *n* ≥ 3 `.` | ⌊n/3⌋ `…` (U+2026) followed by n mod 3 `.`: `...` → `…`, `....` → `….` |

Nothing else changes. Applying ADR 0028's table to the result gives back exactly the ASCII it came from (`“ ”` → `"`,
`‘ ’` → `'`, `—` → `--`, `…` → `...`), for every input: a property tests can check. Vectors are in the appendix (C1).

---

## 6. Copy Review: the HTML and plain-text layouts

Copy Review puts two representations on the clipboard: HTML (`public.html`) and plain text
(`public.utf8-plain-text`). The look below (fonts, sizes, colors, labels) is a **starting candidate** for the
aesthetic gate (§9 Q12), not a decision.

### 6.1 Gmail-safe HTML rules

- **Inline styles only**: no `<style>` blocks, no `class` or `id` attributes, no external resources.
- Elements used: `div`, `p`, `span`, `b`, `i`. No tables, lists, headings, forms or `blockquote` (Gmail's compose
  window restyles headings and quotes on paste).
- **ASCII bytes only.** `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`; every character above U+007E is a
  hexadecimal reference, uppercase, at least four digits (`&#x2019;`). So the clipboard's encoding can't garble it.
- One element per line, `\n` line endings, a final `\n`.

### 6.2 The HTML layout

Where `GRAY` is `#666666` and `MARK` is `#FFF2A8`:

```html
<div style="font-family:Georgia,serif;font-size:16px;line-height:1.5;color:#222222;">
<p style="margin:0 0 4px 0;font-size:22px;font-weight:bold;">Review of BOOK TITLE</p>
<p style="margin:0 0 24px 0;color:GRAY;">DATE</p>
<p style="margin:0 0 8px 0;font-size:18px;font-weight:bold;">General notes</p>
<p style="margin:0 0 8px 0;">GENERAL NOTES PARAGRAPH</p>
<p style="margin:24px 0 8px 0;font-size:18px;font-weight:bold;">SCENE TITLE</p>
<div style="margin:0 0 16px 0;">
<p style="margin:0;">&#x2610; <span style="color:GRAY;">BEFORE</span><span style="background-color:MARK;">PASSAGE</span><span style="color:GRAY;">AFTER</span></p>
<p style="margin:4px 0 0 28px;">COMMENT</p>
</div>
<div style="margin:0 0 16px 0;">
<p style="margin:0;">&#x2610; DETACHED COMMENT</p>
</div>
<p style="margin:16px 0 4px 0;font-weight:bold;">Notes</p>
<p style="margin:0 0 8px 0;">NOTES PARAGRAPH</p>
</div>
```

| Part | Rule |
| --- | --- |
| Header | `Review of ` + the book title. The second line is the date, `MMMM d, yyyy` in English: `November 4, 2026` (§9 Q12). No reviewer name (§9 Q10). |
| General notes | The `General notes` line and one `p` per paragraph; left out when there are none. An empty paragraph is `<p style="margin:0 0 8px 0;"><br></p>`. |
| Scene | The title line, then one `div` per item, then (if the scene has notes) the `Notes` line and one `p` per notes paragraph. |
| Anchored item | `&#x2610; ` (☐, U+2610, and a space), then the quoted paragraph (§5.2): its before piece in a `GRAY` span, the passage in a `MARK` span and its after piece in a `GRAY` span. An empty piece has no span. The comment `p` is left out when the comment text is empty. |
| Detached item | One `p`: `&#x2610; ` and the comment text. |
| Styled text | Within a span or paragraph, each maximal run of one style is wrapped, outermost first, in `<b>`, `<i>` and `<span style="text-decoration:line-through;">`. |
| Comment text | A newline in it (`\n` in the file) is `<br>`. |
| Typography | Smartened (§5.3), then escaped (§6.1). |

### 6.3 The plain-text layout

The same report as UTF-8 text, `\n` line endings, a final `\n`, no hard wrapping. Styles are dropped, and in each quoted
paragraph the passage is marked by square brackets (§5.2).

```
Review of BOOK TITLE
DATE

General notes
-------------

GENERAL NOTES PARAGRAPH

SCENE TITLE
-----------

☐ BEFORE[PASSAGE]AFTER
    COMMENT

☐ DETACHED COMMENT

Notes:

NOTES PARAGRAPH
```

- Each heading (`General notes`, a scene title) is underlined with `-`, as many as the heading has characters.
- Blocks are separated by one blank line. An anchored item is its passage line, then the comment's lines, each
  indented four spaces (a newline in the comment starts a new indented line). A detached item is one line.
- An empty paragraph is an empty line between blank lines (so three blank lines in a row).

---

## 7. Save Review…: the standalone `.html`

### 7.1 The file

Save Review… writes **one self-contained HTML file** (the default name is `<copy name> review.html`, §9 Q12): the
report of §6.2 with real checkboxes, readable in any browser, with no app, no external resources and no network.

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Review of BOOK TITLE</title>
</head>
<body style="margin:0;padding:32px;background-color:#FFFFFF;">
<div style="max-width:40em;margin:0 auto;">
<noscript><p style="margin:0 0 16px 0;padding:8px 12px;background-color:#F2F2F2;font-family:Georgia,serif;">JavaScript is turned off, so the boxes you tick won&#x2019;t be remembered.</p></noscript>
<p id="no-storage" hidden style="margin:0 0 16px 0;padding:8px 12px;background-color:#F2F2F2;font-family:Georgia,serif;">This browser won&#x2019;t let the page remember the boxes you tick.</p>
THE REPORT (§6.2), WITH CHECKBOXES (§7.2)
</div>
<script>
SCRIPT (§7.3)
</script>
</body>
</html>
```

- The body **is** §6.2's HTML, byte for byte, with one substitution (§7.2), so the clipboard and the file can't drift.
- The Content-Security-Policy forbids every fetch, image, font, frame and connection: the page can't touch the
  network even if a future change tried to.
- The title is the header's first line, smartened and escaped.

### 7.2 The checkboxes

In each item, the `&#x2610; ` (the ☐ and its space) is replaced by

```html
<input type="checkbox" data-item="SCENE-ID/COMMENT-ID" aria-label="Done" style="margin:0 8px 0 0;">
```

where `SCENE-ID/COMMENT-ID` is the copy scene's id, `/`, and the comment's id. Ids use only `A–Z a–z 0–9 _ -`, so the
value needs no escaping, and it's unique in the review (comment ids are unique per scene). The checkbox is the first
child of the item's first `p`, whose parent is the item's `div`: the script relies on that structure.

### 7.3 The script, and localStorage

Ticks are kept in the browser's `localStorage` under the key `sceneit.review.<review id>` (§3.2), as a JSON object
whose keys are the ticked items' `data-item` values, each mapped to `true`. Keying by the review id means two
reviews of the same copy never share ticks, and saving a newer version of the same review keeps the ticks of the
comments it still has. A ticked item is dimmed to half opacity (§9 Q12). The script, verbatim (with the review id
substituted):

```js
(function () {
  "use strict";
  var key = "sceneit.review.REVIEW-ID";
  var notice = document.getElementById("no-storage");
  var store = null;
  try { store = window.localStorage; store.getItem(key); } catch (e) { store = null; }
  var ticked = {};
  if (store !== null) {
    try { ticked = JSON.parse(store.getItem(key) || "{}") || {}; } catch (e) { ticked = {}; }
  } else {
    notice.hidden = false;
  }
  function show(box) { box.parentNode.parentNode.style.opacity = box.checked ? "0.5" : "1"; }
  function save(box) {
    var item = box.getAttribute("data-item");
    if (box.checked) { ticked[item] = true; } else { delete ticked[item]; }
    if (store === null) { return; }
    try { store.setItem(key, JSON.stringify(ticked)); } catch (e) { notice.hidden = false; }
  }
  var boxes = document.querySelectorAll("input[data-item]");
  for (var i = 0; i < boxes.length; i++) {
    boxes[i].checked = ticked[boxes[i].getAttribute("data-item")] === true;
    show(boxes[i]);
    boxes[i].addEventListener("change", function (event) { save(event.target); show(event.target); });
  }
})();
```

### 7.4 Without JavaScript, or without storage

- **JavaScript off:** the `<noscript>` note shows above the report. The checkboxes still work while the page is open,
  but aren't remembered or dimmed.
- **JavaScript on, storage refused** (some browsers restrict `localStorage` for `file:` pages): the script reveals the
  `no-storage` note; boxes tick and dim but aren't remembered.
- In every case the report itself reads exactly as the email does.

---

## 8. Worked example

### 8.1 The review copy, `My Novel.md`

The author exported two scenes. *The ferry*'s second paragraph and *Arrival*'s ellipsis are there to show smartening.

```markdown
---
title: My Novel
format: 2
export: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
exported: 2026-11-03T10:15:00-08:00
---

## The ferry
id: 01JCM9S346Q3D25VT4F5V37E3S
modified: 2026-11-02T09:00:00-08:00

The ferry left at dawn, and Mara watched the *harbor lights* go out one by one behind her.

"Don't look back," the deckhand said -- and she didn't.

## Arrival
id: 01JC3E28JT97KB6CQ643DZVMXX
modified: 2026-11-02T03:18:00-08:00

Nobody met her at the landing, which she had half expected and wholly dreaded.

At the top of the hill she stopped, set down the suitcase that had been her mother's, and looked for a long time at the house... it had been painted **blue**.
```

Body plain texts: *The ferry* is 144 characters (88, `\n`, 55); `harbor lights` is `c45-58`. *Arrival* is 233
characters (78, `\n`, 154); `the house` is `c195-204`.

### 8.2 The review file, `My Novel.review.md`

The reviewer wrote three comments (one detached, a comment on the scene as a whole), general notes, and notes on
*Arrival*.

```markdown
---
title: My Novel
format: 1
copy: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
id: 01JDD8WQ4K7M2N9P3R5S6T8V0X
---

### Notes
Overall: I couldn't put it down. The *last line* of "Arrival" is the best thing here.

## The ferry
id: 01JCM9S346Q3D25VT4F5V37E3S

### Comments
- c1 | red | 2026-11-04T09:12:00-08:00 | c45-58 | "harbor lights" | Lovely -- but is it too pretty for Mara's mood?
- c2 | gray | 2026-11-04T09:30:00-08:00 | detached | The deckhand's line feels like a cliche. Cut it?

## Arrival
id: 01JC3E28JT97KB6CQ643DZVMXX

### Notes
The arrival is *strong*. I'd keep the suitcase.

### Comments
- c1 | blue | 2026-11-04T09:41:00-08:00 | c195-204 | "the house" | Which house? Remind us it's her mother's.
```

It's canonical: parsing it against §8.1 and serializing gives the same bytes, with no error entries. Note that both
scenes have a `c1`: comment ids are per scene.

The quoted paragraphs: *The ferry* `c1` quotes its scene's first paragraph (offsets 0–88), and *Arrival* `c1` its
scene's second (79–233), each in full, with the passage marked.

The outputs below are the rules' exact result, computed by a reference sketch of §5.2–§5.3.

### 8.3 Copy Review's HTML

Copied on November 4, 2026:

```html
<div style="font-family:Georgia,serif;font-size:16px;line-height:1.5;color:#222222;">
<p style="margin:0 0 4px 0;font-size:22px;font-weight:bold;">Review of My Novel</p>
<p style="margin:0 0 24px 0;color:#666666;">November 4, 2026</p>
<p style="margin:0 0 8px 0;font-size:18px;font-weight:bold;">General notes</p>
<p style="margin:0 0 8px 0;">Overall: I couldn&#x2019;t put it down. The <i>last line</i> of &#x201C;Arrival&#x201D; is the best thing here.</p>
<p style="margin:24px 0 8px 0;font-size:18px;font-weight:bold;">The ferry</p>
<div style="margin:0 0 16px 0;">
<p style="margin:0;">&#x2610; <span style="color:#666666;">The ferry left at dawn, and Mara watched the </span><span style="background-color:#FFF2A8;"><i>harbor lights</i></span><span style="color:#666666;"> go out one by one behind her.</span></p>
<p style="margin:4px 0 0 28px;">Lovely &#x2014; but is it too pretty for Mara&#x2019;s mood?</p>
</div>
<div style="margin:0 0 16px 0;">
<p style="margin:0;">&#x2610; The deckhand&#x2019;s line feels like a cliche. Cut it?</p>
</div>
<p style="margin:24px 0 8px 0;font-size:18px;font-weight:bold;">Arrival</p>
<div style="margin:0 0 16px 0;">
<p style="margin:0;">&#x2610; <span style="color:#666666;">At the top of the hill she stopped, set down the suitcase that had been her mother&#x2019;s, and looked for a long time at </span><span style="background-color:#FFF2A8;">the house</span><span style="color:#666666;">&#x2026; it had been painted <b>blue</b>.</span></p>
<p style="margin:4px 0 0 28px;">Which house? Remind us it&#x2019;s her mother&#x2019;s.</p>
</div>
<p style="margin:16px 0 4px 0;font-weight:bold;">Notes</p>
<p style="margin:0 0 8px 0;">The arrival is <i>strong</i>. I&#x2019;d keep the suitcase.</p>
</div>
```

The `&#x2026;` after `the house` is the manuscript's own `...`, smartened.

### 8.4 Copy Review's plain text

```
Review of My Novel
November 4, 2026

General notes
-------------

Overall: I couldn’t put it down. The last line of “Arrival” is the best thing here.

The ferry
---------

☐ The ferry left at dawn, and Mara watched the [harbor lights] go out one by one behind her.
    Lovely — but is it too pretty for Mara’s mood?

☐ The deckhand’s line feels like a cliche. Cut it?

Arrival
-------

☐ At the top of the hill she stopped, set down the suitcase that had been her mother’s, and looked for a long time at [the house]… it had been painted blue.
    Which house? Remind us it’s her mother’s.

Notes:

The arrival is strong. I’d keep the suitcase.
```

### 8.5 Save Review…'s file

§7.1's document with the title `Review of My Novel`, the body of §8.3 with these three substitutions (one per item),
and the script with `REVIEW-ID` = `01JDD8WQ4K7M2N9P3R5S6T8V0X`:

| Item | `&#x2610; ` becomes |
| --- | --- |
| *The ferry* `c1` | `<input type="checkbox" data-item="01JCM9S346Q3D25VT4F5V37E3S/c1" aria-label="Done" style="margin:0 8px 0 0;">` |
| *The ferry* `c2` | `<input type="checkbox" data-item="01JCM9S346Q3D25VT4F5V37E3S/c2" aria-label="Done" style="margin:0 8px 0 0;">` |
| *Arrival* `c1` | `<input type="checkbox" data-item="01JC3E28JT97KB6CQ643DZVMXX/c1" aria-label="Done" style="margin:0 8px 0 0;">` |

Ticking *Arrival*'s item stores `{"01JC3E28JT97KB6CQ643DZVMXX/c1":true}` under
`sceneit.review.01JDD8WQ4K7M2N9P3R5S6T8V0X`.

---

## 9. Decisions

The owner decided every question on 2026-11-03 (PR #83). The recommendation was taken except for **Q10 and Q11,
which changed**; this document follows every decision.

| # | Question | Decision |
| --- | --- | --- |
| Q1 | **The marker.** How does a copy mark itself, and how does a review bind to it? | Approved: `export: <ULID>` (fresh per export) and `exported: <timestamp>` in the copy's front matter; `copy: <export id>` and `id: <review id>` in the review's. Distinct keys, so neither file can be mistaken for the other, whatever it's named (§2.3). |
| Q2 | **`modified` in the copy.** | Approved: keep it. The book grammar requires it. |
| Q3 | **A `.md` that isn't a review copy.** | Refuse it, with an alert (§2.3). |
| Q4 | **A copy from a newer Scene It** (`format: 3`). | Refuse it, and ask the reviewer to update (§2.3). |
| Q5 | **General notes** for the review as a whole. | Yes: the review's preamble `### Notes`, shown first in Copy Review (§3.3, §5.1). |
| Q6 | **Comments on a scene as a whole.** | Add **Comment on Scene**: a detached comment, shown as a ☐ item with no passage (§3.5). Notes get no checkboxes. |
| Q7 | **Comment colors in the output.** | Left out (§3.5). |
| Q8 | **Orphan sections.** | Kept as review-level `[line]` entries plus a notice (§3.4). |
| Q9 | **Where a review's backups and kept originals go.** | `~/Library/Application Support/Scene It/Reviews/<review id>/`; only the review file sits beside the copy. #80 implements it. |
| Q10 | **The reviewer's name.** | **Changed: no reviewer name.** Reviews are anonymous: no prompt, no preference, no name in the review file (§3.2) or the output (§5.1). |
| Q11 | **How much text a comment quotes.** | **Changed: the whole paragraph**, with the passage marked, instead of the drafted sentence with 60/160-character limits. Comments on the same paragraph each quote it in full. The passage is a yellow-background span in HTML and in square brackets in plain text (§5.2). |
| Q12 | **The look and the wording**: fonts, colors, indents, heading sizes, labels (`Review of …`, `General notes`, `Notes`, `Notes:`, `(untitled scene)`), the date format, `[passage]` and ` ¶ ` in plain text, dimming ticked items, the `noscript` and storage notes, notices, alerts, the default name `<copy name> review.html`. | Deferred to the renders in #81, with this draft as the first candidate. |
| Q13 | **Smartening edge cases.** | Approved as specified (§5.3), with the lists kept as data in one place. |
| Q14 | **A second review beside the same copy name.** | `X-2.review.md`, …; Scene It never renames or overwrites a review (§4.1, §4.3). |
| Q15 | **Order and omissions in the output.** | Comments in text order, detached ones last; scenes with nothing are left out; no scene numbers (§5.1). |
| Q16 | **The export date in the output's header.** | Not shown (§5.1). |

---

## Appendix: corpus-style cases

Proposed test vectors in the style of [`Tests/Corpus`](../../Tests/Corpus/README.md) (whose conventions they follow:
`entries.txt` lines are `<origin> <reason> - [<tag>] <payload>`, in the Errors tab's order). They're listed here for
review and become files when the formats are implemented (#79, #80, #81); this change doesn't touch `Tests/`. The
proposed layout:

```
Tests/Corpus/
  review-copy/<case>/     input.md, expected.md, entries.txt, recognised.txt
  review/<case>/          copy.md, input.review.md, expected.review.md, entries.txt
  review-output/<case>/   copy.md, review.md, copied-at.txt, expected.html, expected.txt, expected-standalone.html
```

`recognised.txt` holds the export id the copy is recognised by, or `not a review copy`. For `review/` cases the fresh
review id comes from the corpus's id generator (`id-A0`, …); scene ids in copies never do (§2.4).

### A. Review copies (review-copy mode)

The copy used by most cases, called **TIDE**:

```markdown
---
title: Tide
format: 2
export: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
exported: 2026-11-03T10:15:00-08:00
---

## Dawn
id: s1
modified: 2026-11-02T09:00:00-08:00

The ferry left at dawn.

## Dusk
id: s2
modified: 2026-11-02T09:00:00-08:00

The gulls came home.
```

| Case | `input.md` | `expected.md` | `entries.txt` | `recognised.txt` |
| --- | --- | --- | --- | --- |
| `s2.1-recognised` | TIDE | TIDE | empty | `01JDB2C7Q9X4M8T6V3N5R1K0PZ` |
| `s2.3-no-export-is-not-a-copy` | TIDE without its `export` line | TIDE without its `export` line | empty | `not a review copy` |
| `s2.4-positional-id` | TIDE with *Dusk*'s `id: s2` line removed | TIDE with `id: scene-2` for *Dusk*, and after its paragraph `### Unparsed⏎- [notice] This scene had no id, so it was given scene-2.` | `new notice - [notice] This scene had no id, so it was given scene-2.` | `01JDB2C7Q9X4M8T6V3N5R1K0PZ` |
| `s2.4-positional-id-in-use` | TIDE with *Dusk*'s id removed and *Dawn*'s id `scene-2` | *Dawn* keeps `scene-2`; *Dusk* gets `scene-2-2`, with its notice | `new notice - [notice] This scene had no id, so it was given scene-2-2.` | as above |
| `s2.4-mangled-in-the-mail` | TIDE with `\r\n` endings and *Dawn*'s paragraph wrapped as `The ferry left⏎at dawn.` (`properties.txt`: `has-crlf`) | TIDE | empty | as above |

And in **book** mode (the existing `Tests/Corpus/book/` group), one case shows that books are unchanged:

| Case | `input.md` | `expected.md` | `entries.txt` |
| --- | --- | --- | --- |
| `book/s1.5-review-copy-keys-in-a-book` | TIDE | `---⏎title: Tide⏎format: 2⏎---⏎⏎### Unparsed⏎- [front matter] export: 01JDB2C7Q9X4M8T6V3N5R1K0PZ⏎- [front matter] exported: 2026-11-03T10:15:00-08:00⏎⏎` then TIDE's two scenes | `new unknown-key - [front matter] export: 01JDB2C7Q9X4M8T6V3N5R1K0PZ` and `new unknown-key - [front matter] exported: 2026-11-03T10:15:00-08:00` |

### B. Review files

Every case's `copy.md` is TIDE. *Dawn*'s text is `The ferry left at dawn.` (`ferry` is `c4-9`); *Dusk*'s is
`The gulls came home.` (`gulls` is also `c4-9`). **FM** is this front matter:

```
---
title: Tide
format: 1
copy: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
id: 01JDD8WQ4K7M2N9P3R5S6T8V0X
---
```

**B1 `s3.5-comments-and-detached`** (canonical; `expected.review.md` = `input.review.md`; no entries):

```
FM

## Dawn
id: s1

### Comments
- c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | "ferry" | Which ferry?
- c2 | gray | 2026-11-04T09:30:00-08:00 | detached | Too short?
```

**B2 `s3.5-quote-checked-against-the-copy`**: the quote is right for *Dusk*, but this section is *Dawn*.

```
FM

## Dawn
id: s1

### Comments
- c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | "gulls" | Which gulls?
```

`expected.review.md`: the same, with `### Comments` and its entry replaced by
`### Unparsed⏎- [comments] - c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | "gulls" | Which gulls?`.
`entries.txt`: `new E9 - [comments] - c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | "gulls" | Which gulls?`

**B3 `s3.5-notes-range-is-e7`**: as B2 with the entry `- c1 | red | 2026-11-04T09:12:00-08:00 | notes c0-3 | "The" | Hm.`
Result: that line in `### Unparsed`; `entries.txt`: `new E7 - [comments] - c1 | red | 2026-11-04T09:12:00-08:00 | notes c0-3 | "The" | Hm.`

**B4 `s3.4-orphan-section`**:

```
FM

## Noon
id: s9

### Notes
Too short.

## Dusk
id: s2

### Notes
Lovely.
```

`expected.review.md`:

```
FM

### Unparsed
- [line] ## Noon
- [line] id: s9
- [line] ### Notes
- [line] Too short.
- [notice] There's no scene with id s9 in this review copy, so that section's lines were kept as entries.

## Dusk
id: s2

### Notes
Lovely.
```

`entries.txt`: `new line` for each of the four `[line]` entries, then
`new notice - [notice] There's no scene with id s9 in this review copy, so that section's lines were kept as entries.`

**B5 `s3.4-section-without-id`**: `FM⏎⏎## Dawn⏎⏎### Notes⏎Quick.⏎` gives review-level `### Unparsed` entries
`[line] ## Dawn`, `[line] ### Notes`, `[line] Quick.` and
`[notice] A scene section had no id, so its lines were kept as entries.`, and no scene sections.

**B6 `s3.9-sections-merged-retitled-and-sorted`** (silent; no entries):

```
FM

## Dusk (draft)
id: s2

### Notes
Lovely.

## Dawn
id: s1

### Comments
- c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | "ferry" | Which ferry?

## Dawn again
id: s1

### Notes
Quick.
```

`expected.review.md`:

```
FM

## Dawn
id: s1

### Notes
Quick.

### Comments
- c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | "ferry" | Which ferry?

## Dusk
id: s2

### Notes
Lovely.
```

**B7 `s3.2-missing-keys`**: `---⏎title: Tide⏎---⏎⏎## Dawn⏎id: s1⏎⏎### Notes⏎Quick.⏎`

`expected.review.md`:

```
---
title: Tide
format: 1
copy: 01JDB2C7Q9X4M8T6V3N5R1K0PZ
id: id-A0
---

### Unparsed
- [notice] The file had no format line; it was read as format 1.
- [notice] This review had no copy line, so it was taken to be the review of this copy, 01JDB2C7Q9X4M8T6V3N5R1K0PZ.
- [notice] This review had no id, so it was given id-A0.

## Dawn
id: s1

### Notes
Quick.
```

`entries.txt`: the three notices, each `new notice`.

**B8 `s3.4-body-lines-and-marks`**: `FM⏎⏎## Dawn⏎id: s1⏎Loved it.⏎⏎### Marks⏎- color red | c0-3 | "The"⏎`. `Loved it.`
ends the metadata block and is a body line; `### Marks` isn't understood and leaves the (body) section current, so the
mark line is a body line too. `expected.review.md`: `FM`, then `## Dawn⏎id: s1⏎⏎### Unparsed⏎- [line] Loved it.⏎- [line] ### Marks⏎- [line] - color red | c0-3 | "The"⏎`.
`entries.txt`: three `new line` entries.

**B9 `s3.4-metadata-other-than-id`**: `FM⏎⏎## Dawn⏎id: s1⏎modified: 2026-11-02T09:00:00-08:00⏎⏎### Notes⏎Quick.⏎`.
`expected.review.md`: *Dawn*'s section with `### Notes⏎Quick.` then `### Unparsed⏎- [metadata] modified: 2026-11-02T09:00:00-08:00`.
`entries.txt`: `new unknown-key - [metadata] modified: 2026-11-02T09:00:00-08:00`.

### C. Output

**C1. Smartening vectors** (§5.3), each a whole unit:

| Input (ASCII) | Output |
| --- | --- |
| `"Don't look back," the deckhand said -- and she didn't.` | `“Don’t look back,” the deckhand said — and she didn’t.` |
| `'Tis the '90s, rock 'n' roll... "'Hi,' she said." Wait-- "Go!"` | `’Tis the ’90s, rock ’n’ roll… “‘Hi,’ she said.” Wait— “Go!”` |
| `He said "no"--"yes." ---- dashes. ....` | `He said “no”—“yes.” ---- dashes. ….` |
| `the boys' boat` | `the boys’ boat` |
| `("quoted")` | `(“quoted”)` |

For every row, ADR 0028's table applied to the output gives the input back.

**C2. Quoted paragraphs** (§5.2), as plain text with the passage in brackets:

| `T` | Range | Shown |
| --- | --- | --- |
| `He stopped. Mr. Grant waved. "Come in!" she said. Nobody moved.` | `c22-27` (`waved`) | `He stopped. Mr. Grant [waved]. “Come in!” she said. Nobody moved.` |
| same, a second comment on the same paragraph | `c40-48` (`she said`) | `He stopped. Mr. Grant waved. “Come in!” [she said]. Nobody moved.` (each item quotes the paragraph in full) |
| same | `c30-37` (`Come in`) | `He stopped. Mr. Grant waved. “[Come in]!” she said. Nobody moved.` (the `“` is in the before piece, and still opens) |
| `First paragraph.⏎Second one here.` | `c24-27` (`one`) | `Second [one] here.` (only the paragraph the passage is in) |
| `It rained.⏎She left at once.` | `c3-14` | `It [rained. ¶ She] left at once.` (a passage spanning paragraphs quotes both) |
| `Wait -- what?` | `c5-6` (the first `-`) | `Wait [-]- what?` (the `--` straddles a piece boundary, so neither piece holds a pair) |

**C3. `review-output/s8-worked-example`**: `copy.md` is §8.1, `review.md` is §8.2, `copied-at.txt` is
`2026-11-04T10:00:00-08:00`; `expected.html` is §8.3, `expected.txt` is §8.4, and `expected-standalone.html` is §8.5.
Also checked on it: `expected.html` is ASCII and contains no `<style`, `class=` or `id=`; and every character of
manuscript text in the output lies in a paragraph that some comment quotes (§5.2), so the output never holds more of
the manuscript than those paragraphs.
