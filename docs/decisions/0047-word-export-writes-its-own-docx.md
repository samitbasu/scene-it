# 0047 — Export to Word writes its own .docx

**Status:** Accepted (2026-11-09, the owner, on #174). Amends PLAN §10.2's "How" and
[0045](0045-word-export-title-is-heading-1.md)'s "after macOS writes the .docx"; 0045's decision (the
title is Word's Heading 1 and looks as before) stands. Implemented in #37. Added to by
[0048](0048-word-export-can-include-comments.md): the comments can be written too.

## Context
PLAN §10.2 said to build an `NSAttributedString` and write it with the `.officeOpenXML` document
type, and 0045 added a post-processing step to mark the title as Heading 1. Implementing that showed
macOS 27's writer falls short of §10.2 in more ways than the heading:
- **Line spacing is dropped** (`lineHeightMultiple`, `lineSpacing` and fixed line heights all vanish),
  so the body couldn't be double-spaced.
- **Highlights are dropped** (`.backgroundColor` isn't written).
- **Colours are darkened:** they're converted to another colour space, so the palette's red `C62828`
  is written `B7141F`.
- **It writes a non-standard dialect:** Word 2003 names such as `w:first-line` and `w:sz-cs`, properties
  out of the schema's order, and no `styles.xml`.

Patching all of that meant reading macOS's zip, finding its runs, matching them to the scene by text
and rewriting them. That depends on undocumented behaviour of the writer (how it splits runs, what it
names things), which a macOS update could change on users' machines, after we've tested and shipped.

## Decision
Scene It writes the .docx itself, a minimal, standard-conformant WordprocessingML package:
- **Parts:** `[Content_Types].xml`, `_rels/.rels`, `word/document.xml`, `word/_rels/document.xml.rels`,
  `word/styles.xml` and `word/settings.xml`, which sets Word's current compatibility mode (15) so
  Word doesn't open the document in Compatibility Mode. No document properties, theme or section
  properties: Word doesn't need them, and its own default page setup applies.
- **Styles** (`WordStyles`): `Normal`, the default, Times New Roman 12 pt, double-spaced
  (`w:line="480" w:lineRule="auto"`) with a half-inch first-line indent; `Heading1` ("heading 1"),
  based on it, 18 pt bold black, single-spaced, not indented, outline level 0. The sizes and the
  indent come from the constants the page uses (`ParagraphRole`).
- **The document:** the title paragraph has `pStyle Heading1`; body paragraphs have no properties, so
  they take `Normal`. Each run carries only what the scene says: bold, italic, strikethrough, a
  palette colour (`w:color`) and a highlight as shading (`w:shd`, the palette's fill), in the schema's
  order; uncoloured text has no `w:color`, so it's Word's automatic colour. Notes aren't written, nor
  comments unless the writer asks for them (0048).
- **Text** is the stored text, which `CharacterPolicy` keeps to printable ASCII, smartened as print
  smartens it (decision 0022; added by #35, which also joins neighbouring runs Word would format alike).
  One function escapes XML's markup characters and guarantees well-formed XML on its own: a character
  XML can't hold refuses the export (`WordExportFailure.unwritableCharacter`) in every build. (The
  first version also asserted the character policy; smartened text holds characters the policy
  refuses, so #35 dropped that tripwire.)
- **The zip** is written by an owned, writer-only `ZipWriter` of about 100 lines: stored entries (no
  compression), a CRC-32 from the system zlib, fixed dates so the same scene makes the same bytes. No
  dependency, no subprocess.
- The tests read the result only with macOS's own `unzip` and `zipinfo` and assert the XML with XPath.

## Alternatives
- **macOS's writer, patched (0045 as first implemented, #174's first version).** Keeps the system
  writer, but fixes four kinds of loss by editing its output, and breaks if the writer changes.
- **macOS's writer, unpatched.** Loses double spacing, highlights and exact colours, and the heading.
- **A third-party .docx or zip library.** A dependency to add, update and trust, for a need of about
  100 lines: a writer-only zip of a handful of small parts.
- **Deflated entries.** Smaller files, but a compressor's output and failure modes to depend on, for
  documents of a few kilobytes; Word and Pages read stored entries.

## Learning notes
A .docx is an Open Packaging Convention zip: `[Content_Types].xml` gives every part's type,
`_rels/.rels` points at the main document, and each part's own `_rels` folder links it to the parts it
uses (here, the styles). In WordprocessingML a paragraph (`w:p`) holds runs (`w:r`) of text (`w:t`);
`w:pPr` and `w:rPr` hold their properties, whose children must come in the order the schema lists.
A paragraph without a `w:pStyle` takes the style marked `w:default="1"`.
