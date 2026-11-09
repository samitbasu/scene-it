# 0045 — Export to Word marks the scene title as Heading 1

**Status:** Accepted (2026-11-09, the owner, on #36), amended by [0047](0047-word-export-writes-its-own-docx.md). Resolves PLAN §9 Q5; implemented in #37.

## Context
PLAN §10.2 writes the .docx with `NSAttributedString`'s `.officeOpenXML` document type. That writer
applies direct formatting only: the title is Times New Roman 18 pt bold, but Word sees an ordinary
paragraph, so it's missing from Word's Navigation pane, a table of contents and screen readers'
heading lists.

## Decision
After macOS writes the .docx, a small post-processing step gives the title paragraph Word's built-in
`Heading1` style, with that style defined as Times New Roman 18 pt bold, so the page looks exactly as
before. The body text keeps its direct formatting. The step is tested on the produced XML (the title
paragraph's `w:pStyle` is `Heading1`, and `styles.xml` defines it), and the file must still open in
Word and Pages (a manual check in PLAN §13).

## Alternatives
- **Direct formatting only.** Simplest, and it looks right, but the title isn't a heading to Word;
  that matters once scenes are combined into a manuscript for an editor.

## Learning notes
A .docx is a zip of XML parts (Office Open XML). A paragraph's named style is `<w:pStyle w:val="…"/>`
inside its `<w:pPr>`, and the style itself is declared in `word/styles.xml`.
