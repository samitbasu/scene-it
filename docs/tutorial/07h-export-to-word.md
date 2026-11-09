# 07h — Export to Word: a system writer, and fixing up what it writes

Issue #37 (PLAN §10.2, ADR 0045). File → Export to Word… saves the open scene as a `.docx`: the
title in Times New Roman 18 pt bold, the body in 12 pt, double-spaced with a half-inch first-line
indent, with bold, italic, strikethrough, colours and highlights, and without the comments. macOS
writes the document; Scene It then edits the XML inside it. The Swift and macOS lessons: what
`NSAttributedString`'s document writers do and don't do, a `.docx` as a zip of XML parts, reading
and writing a zip with only the system's libraries, Foundation's XML DOM, and one safe-write path
for every file the writer chooses.

Files: [`Sources/SceneItCore/Word/WordExport.swift`](../../Sources/SceneItCore/Word/WordExport.swift),
[`Sources/SceneItCore/Word/WordPackage.swift`](../../Sources/SceneItCore/Word/WordPackage.swift),
[`Sources/SceneItCore/Word/WordStyles.swift`](../../Sources/SceneItCore/Word/WordStyles.swift),
[`Sources/SceneItCore/Word/ZipArchive.swift`](../../Sources/SceneItCore/Word/ZipArchive.swift),
[`Sources/SceneItCore/Word/WordDocumentWriter.swift`](../../Sources/SceneItCore/Word/WordDocumentWriter.swift),
[`SceneIt/Books/ExportToWord.swift`](../../SceneIt/Books/ExportToWord.swift),
[`Tests/SceneItCoreTests/Word/WordExportTests.swift`](../../Tests/SceneItCoreTests/Word/WordExportTests.swift).

## 1. `NSAttributedString` writes Word documents, approximately

AppKit can serialize an attributed string as RTF, HTML, `.doc` and `.docx`. For a `.docx` it's one
call:

```swift
written = try text.data(
    from: NSRange(location: 0, length: text.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
```

That is the whole of PLAN §10.2's "How", and the attributed string is built from the model the way
the page builds its own: each `Run` goes through the codec's one mapping, `RunFormat`, so the export
can't spell bold or a palette colour differently from the editor. Comments are cleared from each
run's format first, and the paragraph style is the export's own.

Then the tests looked at what macOS actually wrote, and found it's a dialect. It keeps fonts, sizes,
bold, italic, strikethrough and text colours, but:

- **line spacing is dropped**: `lineHeightMultiple`, `lineSpacing` and fixed line heights all vanish;
- **background colours (highlights) are dropped**;
- **colours are converted** to another colour space, so the palette's red `C62828` comes out
  `B7141F`;
- **there are no named styles**: no `styles.xml`, so Word sees the title as an ordinary paragraph
  (the reason for ADR 0045);
- some names are Word 2003's, not the standard's (`w:first-line`, `w:sz-cs`).

The first test in `WordExportTests` pins exactly these facts about macOS's writer. If a macOS update
starts writing styles or highlights, that test fails and says why the post-processing exists, which
is better than the post-processing silently doubling something up. It's the Rust habit of a test
that asserts an upstream crate's behaviour you depend on.

## 2. A `.docx` is a zip of XML parts

Office Open XML is a zip. The parts that matter here:

| Part | What it holds |
| --- | --- |
| `[Content_Types].xml` | the MIME type of every part |
| `word/document.xml` | the paragraphs (`w:p`) and runs (`w:r`) with their properties (`w:pPr`, `w:rPr`) |
| `word/_rels/document.xml.rels` | links from the document to its other parts |
| `word/styles.xml` | named styles; macOS doesn't write one |

A paragraph's named style is `<w:pStyle w:val="Heading1"/>` inside its `w:pPr`; a paragraph without
one takes the style marked `w:default="1"`. So `WordPackage` does four things: gives the title's
`w:pPr` a `pStyle`, adds `styles.xml` (the body's default style, double-spaced and indented, and
Heading 1, single-spaced, 18 pt bold, so the look is unchanged), lists it in `[Content_Types].xml`,
and links it from the relationships. And for each run it writes the palette's exact colour and, for
a highlight, a shading (`<w:shd w:fill="D9EDDA"/>`).

The measurements in `WordStyles` are derived, not typed in: `ParagraphRole.pointSize` and
`ParagraphRole.firstLineIndent` are the same constants the page lays out with, converted to Word's
units (half-points for type, twentieths of a point for indents, 240ths of a line for spacing).

## 3. A zip with only the system's libraries

Foundation can *make* a zip of a folder (`NSFileCoordinator`'s `.forUploading`, which
`ProblemReport` uses), but has no API to read one. Rather than add a dependency, `ZipArchive` reads
and writes the format directly. It's small because a `.docx` needs little of it: the central
directory at the end lists each entry's offset, sizes and CRC-32; each entry is stored or deflated.

- Deflate is in Foundation: `NSData.decompressed(using: .zlib)` and `compressed(using: .zlib)` are
  raw DEFLATE, the format zip uses (no zlib header, despite the name).
- CRC-32 is in the system's zlib, which Swift imports as a module (`import zlib`), like a `-sys`
  crate that's always there.
- Every read is bounds-checked (`ByteReader` throws `.malformed` rather than trapping), every entry's
  size and checksum is verified, and zip64 and encryption are refused, since a `.docx` never needs
  them.

The tests check the writer against a reader that isn't ours: macOS's `/usr/bin/unzip -t` must find
every entry intact, and every part the export tests assert on is extracted by `unzip`, not by
`ZipArchive`. A test that read our zips with our own reader could pass while both halves shared a
bug.

## 4. Foundation's XML DOM

Foundation has a full XML DOM, `XMLDocument` (on Linux it lives in a separate `FoundationXML`
module; this app is Mac-only). Elements are found by namespace, not by prefix:

```swift
let written = body.elements(forLocalName: "p", uri: Namespace.word)
```

The prefix the document uses for that namespace is looked up (`resolvePrefix(forNamespaceURI:)`)
and used for the elements added, so the output reads as macOS wrote it.

Editing someone else's output is only safe if it's the output you expect. So before changing
anything, `WordPackage` checks it against the scene: the same number of paragraphs, and each
paragraph's runs, joined, are exactly the paragraph's text. Colours are matched to runs by character
offset, and a run whose characters don't all share one colour is refused, not guessed at. Every
"unexpected" is a typed error with a static reason that's logged (never the text, ADR 0006), and the
writer is told the export failed; nothing is written.

## 5. One write for every file the writer chooses

The document goes to disk through `ChosenFileWrite`, the routine Export as SceneIt… and Save
Review… already share ([chapter 07g](07g-copy-and-save-review.md)): written under a hidden name, read
back, then renamed into place. `WordDocumentWriter` adds one guard, as Save Review… does for `.html`:
the name must end in `.docx`, which nothing of a book's or a review's own is ever called.

The conversion runs on the main actor (it's a scene, and AppKit's text system is happiest there);
only the disk write is `@concurrent`. The store takes the scene by id after the save panel closes,
so what's exported is the scene as it is then, saved or not, and a read-only book or review exports
like any other: nothing in it changes.

## What isn't automated

Whether Word and Pages open the file, show the title in the Navigation pane and lay the body out as
expected can't be checked here; it's on the owner's hand-test list.
