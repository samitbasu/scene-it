# 07i — Export to Word: writing a file format yourself

Issue #37 (PLAN §10.2, ADR 0045, ADR 0047). File → Export to Word… saves the open scene as a `.docx`:
the title in Times New Roman 18 pt bold as Word's Heading 1, the body in 12 pt, double-spaced with a
half-inch first-line indent, with bold, italic, strikethrough, colours and highlights, the
punctuation smartened as print's is, and without the comments. The Swift and macOS lessons: when not
to use the system's converter, what a `.docx` is inside, generating XML as text behind one escaping
function, writing a zip
with the system's zlib, and testing a file format with a reader that isn't yours.

Files: [`Sources/SceneItCore/Word/WordExport.swift`](../../Sources/SceneItCore/Word/WordExport.swift),
[`Sources/SceneItCore/Word/WordStyles.swift`](../../Sources/SceneItCore/Word/WordStyles.swift),
[`Sources/SceneItCore/Word/ZipWriter.swift`](../../Sources/SceneItCore/Word/ZipWriter.swift),
[`Sources/SceneItCore/Word/WordDocumentWriter.swift`](../../Sources/SceneItCore/Word/WordDocumentWriter.swift),
[`SceneIt/Books/ExportToWord.swift`](../../SceneIt/Books/ExportToWord.swift),
[`Tests/SceneItCoreTests/Word/WordExportTests.swift`](../../Tests/SceneItCoreTests/Word/WordExportTests.swift),
[`Tests/SceneItCoreTests/Word/ZipWriterTests.swift`](../../Tests/SceneItCoreTests/Word/ZipWriterTests.swift).

## 1. Why not `NSAttributedString`'s writer

AppKit can serialize an attributed string as a `.docx` in one call (`data(from:documentAttributes:)`
with `.officeOpenXML`), and PLAN §10.2 planned to use it. The project's rule is to prefer what a
library computes over an in-house copy, so that was tried first. Unzipping what it wrote showed it
drops line spacing and highlights, writes colours a shade darker (converted to another colour space),
writes no styles, and uses some Word 2003 names (`w:first-line`, `w:sz-cs`) that aren't in the
standard.

The first version of this feature patched the output. That meant matching macOS's runs to the scene
by their text and rewriting them, which depends on how an undocumented writer splits runs and names
things. A macOS update could change either on a user's machine, after we'd tested and shipped. ADR
0047 records the owner's choice to write the document ourselves. The lesson generalizes beyond
Apple: depending on a library's *outputs* that it never promised is a liability, like parsing another
crate's `Debug` output in Rust.

## 2. A `.docx` is a zip of XML parts

Office Open XML uses the Open Packaging Conventions: a zip whose parts are found through
relationships. Scene It's document has six:

| Part | What it holds |
| --- | --- |
| `[Content_Types].xml` | the type of every part |
| `_rels/.rels` | the package's link to its main document |
| `word/document.xml` | paragraphs (`w:p`) of runs (`w:r`) of text (`w:t`) |
| `word/_rels/document.xml.rels` | the document's links to its styles and settings |
| `word/styles.xml` | the named styles |
| `word/settings.xml` | Word's compatibility mode, 15 (Word 2013 on), so Word doesn't open it in Compatibility Mode |

A paragraph's style is `<w:pStyle w:val="Heading1"/>` inside its `w:pPr`; a paragraph without one
takes the style marked `w:default="1"`. So the body's look lives once, in the `Normal` style, and the
title's in `Heading1`, which Word lists in its Navigation pane. The numbers in `WordStyles` are
derived from the page's own constants, converted to Word's units:

```swift
static func halfPoints(_ role: ParagraphRole) -> Int {
    Int(role.pointSize * 2)
}

static let firstLineIndent = Int(ParagraphRole.firstLineIndent * 20)
```

Each run carries only its own formatting, and the schema fixes the order of a run's properties
(bold, italic, strikethrough, colour, shading), so `WordDocument.run` appends them in that order.
Colours come straight from the palette's hex values, the same ones the page draws with. Uncoloured
text gets no `w:color` at all, which Word reads as its automatic colour: black on white, light when
Word shows the document dark.

The text is the stored text smartened (decision 0022): straight quotes become curly, `--` a dash and
`...` an ellipsis. `OutputParagraph.shown` does it, the one rule print uses too ([chapter
09](09-printing.md)): quotes are decided over the whole paragraph, then each run takes its own piece,
so its formatting stays on exactly its characters. Runs Word would format alike are then joined
(`WordDocument.merged`): a comment's edges aren't exported, so they mustn't split a run.

## 3. XML as text, behind one escaping function

The parts are small and fixed in shape, so they're built as strings, Swift's raw string literals
(`#"..."#`, like Rust's `r#"..."#`) keeping the quotes readable. The only text that varies is the
scene's, and all of it passes through one function:

```swift
static func escaped(_ text: String) throws(WordExportFailure) -> String {
    guard text.unicodeScalars.allSatisfy(isXMLCharacter) else { throw .unwritableCharacter }
```

The function keeps its own contract, well-formed XML, in every build. XML 1.0 can't hold most
control characters or U+FFFE and U+FFFF even escaped, so such a character refuses the export with a
typed error and a notice rather than writing a file Word would reject. (A Swift `String` can't hold a
lone surrogate at all, unlike an `NSString`.) Stored text is printable ASCII (ADR 0028), so that path
should never run. The first version also asserted the character policy here, a debug-only tripwire
like Rust's `debug_assert!`; once the text was smartened it held curly quotes and dashes, which the
policy refuses but XML is happy with, so the XML check is the contract that remains. A test builds a
scene containing a control character, bypassing the policy through the model's internal initializer,
and sees the refusal. Another pushes every allowed character through the title and the body and reads
them back, smartened, from the XML.

## 4. A writer-only zip with the system's zlib

Foundation can zip a folder but can't write a zip from data in memory, and the project adds no
dependencies to the core. `ZipWriter` is about 100 lines: for each entry a local header, the bytes and
a central-directory record, then the end record. Entries are *stored*, not compressed: a scene's
document is a few kilobytes, so compression saves nothing that matters and would add a code path that
can fail. The CRC-32 comes from the system's zlib, which Swift imports as a module (`import zlib`),
much like a `-sys` crate that's always present. Every date is 1 January 1980, so the same scene
always makes the same bytes.

## 5. Testing with a reader that isn't yours

The tests never read our zips with our own code, which could share a bug with the writer. They run
macOS's `/usr/bin/unzip -t` (every checksum), `zipinfo -1` (the entries) and `unzip -p` (a part's
bytes), then parse the XML with Foundation's `XMLDocument` and assert with XPath: the title's
`pStyle`, the styles' fonts, sizes, spacing and indent, each run's properties in order and its exact
colour, and that no comment text appears anywhere. `XMLNode`'s XPath can't bind a namespace prefix,
so the tests write `w:p` and a helper turns it into `*[local-name()='p']`.

## 6. One write for every file the writer chooses

The document reaches disk through `ChosenFileWrite`, which Export as SceneIt… and Save Review… share
([chapter 07g](07g-copy-and-save-review.md)): written under a hidden name, read back, then renamed into
place. `WordDocumentWriter` adds one guard: the name must end in `.docx`, which nothing of a book's
or a review's own is called. The store takes the scene by id after the save panel closes, so the
export is the scene as it is then, saved or not. A read-only book or review exports like any other,
since nothing in it changes.

## What isn't automated

Whether Word and Pages open the file, list the title in the Navigation pane and lay out the body as
expected can't be checked here. It's on the owner's hand-test list.
