# 09 — Printing: pages, a margin column and the print dialog

Issue #35 (PLAN §10.1). File → Print… (⌘P) and the toolbar's Print button open the standard macOS
print dialog, with Scene It's two choices in it: a layout (Text only, portrait in manuscript format;
or Text with comments, landscape, with the comments in a column beside the lines they refer to) and
a range (This scene or Whole manuscript; the Boneyard is never printed). The Swift and macOS lessons:
how AppKit prints a view, TextKit 2 without a text view, a pure layout function with property tests,
an accessory in the system's dialog, and testing printing without a printer. Export to Word is
[chapter 07i](07i-export-to-word.md).

Files: [`Sources/SceneItCore/Print/PrintPagination.swift`](../../Sources/SceneItCore/Print/PrintPagination.swift),
[`Sources/SceneItCore/Print/ConnectorLanes.swift`](../../Sources/SceneItCore/Print/ConnectorLanes.swift),
[`Sources/SceneItCore/Print/ManuscriptPages.swift`](../../Sources/SceneItCore/Print/ManuscriptPages.swift),
[`Sources/SceneItCore/Print/PrintManuscript.swift`](../../Sources/SceneItCore/Print/PrintManuscript.swift),
[`Sources/SceneItCore/Text/OutputParagraph.swift`](../../Sources/SceneItCore/Text/OutputParagraph.swift),
[`SceneIt/Print/ManuscriptPrintView.swift`](../../SceneIt/Print/ManuscriptPrintView.swift),
[`SceneIt/Print/PrintAccessory.swift`](../../SceneIt/Print/PrintAccessory.swift),
[`SceneIt/Print/ManuscriptPrinting.swift`](../../SceneIt/Print/ManuscriptPrinting.swift),
[`Tests/SceneItCoreTests/Print/PrintPaginationTests.swift`](../../Tests/SceneItCoreTests/Print/PrintPaginationTests.swift),
[`Tests/SceneItCoreTests/Print/ManuscriptPagesTests.swift`](../../Tests/SceneItCoreTests/Print/ManuscriptPagesTests.swift),
[`SceneItTests/PrintTests.swift`](../../SceneItTests/PrintTests.swift).

## 1. How AppKit prints: a view and its pages

On macOS you don't hand the printer a document; you hand `NSPrintOperation` a view and it asks the
view to draw itself into the printer's graphics context, a page at a time. By default it slices the
view into paper-sized strips. A view that wants its own pages answers two questions:

```swift
override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    let pages = layOut(for: NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared)
    range.pointee = NSRange(location: 1, length: pages.pageCount)
    return true
}
```

and `rectForPage(_:)`, the part of the view that is page *n* (counted from 1). Then `draw(_:)` is
called with that rectangle as the dirty rect. `ManuscriptPrintView` stacks its pages top to bottom,
one sheet of paper each, and the print info has no margins, so a page's rectangle is the whole sheet
and each page draws its own margins, header and comment column. The pointer parameter is one of the
few places Swift shows its C heritage: `NSRangePointer` is `UnsafeMutablePointer<NSRange>`, and
`pointee` is Rust's `*ptr = …`.

The view is asked again whenever the dialog's preview needs it, after the writer changes the paper or
one of Scene It's choices, so it lays its pages out again only when the layout, the range or the paper
has changed. `NSPrintInfo.paperSize` keeps the paper the way it's fed, so the view turns it itself for
the orientation.

## 2. TextKit 2 without a text view

PLAN §10.1 said "an offscreen `NSTextView` laid out for paper". A text view draws one continuous
column, though, and print needs page breaks it chooses and a column beside the text. So
`ManuscriptPages` uses the TextKit 2 objects a text view is built from, and nothing else:

```swift
let content = NSTextContentStorage()
let layout = NSTextLayoutManager()
content.addTextLayoutManager(layout)
let container = NSTextContainer(size: CGSize(width: geometry.text.width, height: 0))
container.lineFragmentPadding = 0
layout.textContainer = container
layout.delegate = underliner
```

That's the model (the storage), the layout engine and the shape to fill (a height of 0 means
unlimited), with the page's own delegate, `CommentUnderliner`, so the layout fragments are the page's
`CommentUnderlineFragment`s: the same double spacing below the line (ADR 0034), the same end line,
the same stacked comment underlines (ADR 0032). The text column is the page's 6.5 in, so lines break
where they do on screen. Nothing here touches `layoutManager`, the TextKit 1 property that silently
switches a text view back to TextKit 1 (the gate's guard forbids the word).

After `ensureLayout`, each `NSTextLayoutFragment` (a paragraph) has a frame and `textLineFragments`,
its lines; the print code measures each line's top and the bottom of its letters. To draw a page, it
clips the context to that page's slice of the text and asks each fragment in the slice to draw
itself, `fragment.draw(at:in:)`, shifted up so the slice starts at the top margin. Page breaks fall
between lines, after a line's spacing, so clipping never cuts a line or an underline.

## 3. The layout is a pure function

Where pages break and where each comment goes depend on each other: a comment that would run off the
bottom of the column takes its line to the next page. That policy is one function with no AppKit in
it:

```swift
public static func pages(
    lines: [PrintLine], comments: [MarginComment], height: PaperLength, spacing: PaperLength
) -> [PrintPage]
```

Lines come in as tops and bottoms, comments as the line they belong to and their height. A comment is
level with the top of its line unless the one above pushes it down. If it would run past the column,
its line starts the next page. Only a comment that can't fit even beside a line at the top of a page
is carried over to the top of the next page's column, and comments behind it wait, so their order
never changes. Each page is a range of lines and its placed comments.

`PaperLength` is the project's newtype rule applied to points: a `CGFloat` that is never negative or
NaN, with `+` and a `-` that stops at zero. Like a Rust newtype with `From` impls, it costs nothing at
run time; `CGFloat(length)` takes the number back out at the drawing boundary.

The tests (`PrintPaginationTests`) check the named cases (pushed down, pushed past the page end, the
last line of a page and of the text, many comments on one line, a comment taller than a column), each
asserting its precondition so it can't quietly stop testing anything. They also check forty random
texts, generated from fixed seeds with a small SplitMix64 generator, against invariants: every line
once and in order, every comment once and in order, none overlapping the next, none above its line,
none outside its column. That's a property test, like `proptest` in Rust, written by hand.

## 4. One text for the page, Word and print

Print and Export to Word put a scene out the same way: its title as a heading (decision 0015), then
its body. `OutputParagraph.paragraphs(of:)` is that rule, shared by both, and so is how the text
looks: `OutputParagraph.shown(_:)` gives each run its text with the typography smartened (decision 0022),
straight quotes turned curly, `--` a dash and `...` an ellipsis. It uses the same `SmartUnit` that Copy
Review uses ([chapter 07g](07g-copy-and-save-review.md)): quotes are decided over the whole paragraph,
then each run takes its piece, so a run's formatting and comments stay on exactly its characters.
Print builds its attributed string with the page's own `RunCodec`, which gained one entry point:

```swift
static func attributedString(forOutput paragraphs: [OutputParagraph]) -> NSAttributedString {
    attributedString(paragraphs.map { ($0.kind.role, $0.shown(.eachRun)) })
}
```

The editors call the same builder with each run's stored text. Word writes `shown(.sameLook)`, which
first joins the runs it would format alike ([chapter 07i](07i-export-to-word.md)). Print keeps each run
a piece, since it underlines each run's comments, so a `--` split only by a comment's edge stays two
hyphens in print, while Word makes it a dash. The comment colors are the palette's,
through the page's `CommentPalette`.

### Connectors that can't be confused

Each comment's connector leaves the text at the end of its underline. If the connectors of one line
all ran right at the underline's depth, they'd coincide and read as underlining the words after them.
`ConnectorLanes` gives each its own lane in the gap below the line, under every underline there and
above the next line's letters, and the column takes a line's comments right to left: the rightmost
gets the top lane and the top box. Then the further left a connector starts, the lower it runs, so it
passes under the others' drops, and no two cross between the gutter and their boxes. The tests check
the lanes are distinct and inside the band, and that the order makes the paths planar.

## 5. An accessory in the system's dialog

The mockup draws the choices as a dialog of its own, with a Print… button. Scene It puts them inside
the standard print dialog instead, as an *accessory*: one dialog, with the system's printers, paper,
copies and Save as PDF, and a live preview that follows the choices. An accessory is an
`NSViewController` that adopts `NSPrintPanelAccessorizing`:

```swift
func keyPathsForValuesAffectingPreview() -> Set<String> {
    [#keyPath(revision)]
}
```

The dialog watches those key paths with Key-Value Observing, Objective-C's property observation, and
redraws its preview when they change. KVO only sees properties declared `@objc dynamic`, so the
controller keeps a counter, `revision`, that it bumps on every change of the SwiftUI choices.
`#keyPath(revision)` is checked by the compiler, unlike a string. The controller's
`representedObject` is the dialog's `NSPrintInfo`, so choosing a layout also turns the paper:
landscape for comments, portrait for text only, a starting point that the dialog's own Orientation
can still change. `localizedSummaryItems()` is what the dialog lists when it's collapsed.

The accessory's look is SwiftUI in an `NSHostingView`, the reverse of chapter 05's bridge.

The menu and the toolbar both go through the window's one `PrintFlow`. The toolbar holds it; the
main window also registers it with `MainWindowChrome`, as it does its focus mode for the View menu,
and File → Print… calls that. There's one book window (ADR 0038), so both print the book that window
shows, as a sheet on that window, which the window reports through `WindowReporter`; and both are
disabled while a rail sheet, a dialog or the print dialog itself is up. What "a rail sheet or a dialog
is up" means is one property, `WindowOverlays.noneUp`, which Export to Word's `WordExportFlow`
reads too, so the two can't disagree about when the window is free. The dialog's end comes back
through an Objective-C selector, `printOperationDidRun(_:success:contextInfo:)`,
which is why `PrintFlow` is an `NSObject`.

## 6. Testing printing without a printer

The hosted tests (`PrintTests`) print the real view to PDF and read the PDF back with PDFKit: the page
count, each page's size (portrait or landscape), and the text, including the comments and where they
are. Two details:

- `NSPrintOperation.pdfOperation(with:inside:to:printInfo:)` looked like the obvious tool, but it made
  the whole view a single tall page, ignoring `knowsPageRange`. The tests instead run an ordinary
  operation whose print info says to save the job to a file (`jobDisposition = .save` and a
  `jobSavingURL` in a temporary folder), which is what Save as PDF in the dialog does. The test
  asserts the disposition before running, so no job can reach a printer.
- The dialog itself is never shown: tests can't press its buttons (and agents never synthesize
  input), so whether it shows the accessory and follows it is on the owner's hand-test list.

A small Swift surprise from the tests: Swift Testing has a type called `Comment` too, so `Comment` is
ambiguous in a test's signatures. The module's own name doesn't help, because `SceneItCore` also
names an enum in the module. The tests write `SceneItCore::Comment`, Swift's *module selector*
syntax, which always means the module.

## What isn't automated

The real print dialog: that the accessory shows and its choices change the preview, that landscape
comments sit level with their lines on paper, and that Save as PDF writes the same pages. These are
on the owner's hand-test list.
