# 07g — Copy Review and Save Review…: one report, three renderers

Issue #81 (ADR 0029, review format §5–§8). With a review open ([chapter 07f](07f-review-book.md)),
File → Copy Review puts the reviewer's comments and notes on the clipboard as HTML and plain text,
for pasting into an email, and File → Save Review… writes the same report as a standalone `.html`
page with real checkboxes that the author can tick in any browser. The Swift and macOS lessons: a
pure intermediate value that several outputs render, so they can't disagree; a two-pass text
transform whose passes work on different extents; typed throws through a shared helper; the
pasteboard's multiple representations; and driving WebKit offscreen from a hosted test.

Files: [`Sources/SceneItCore/Format/ReviewReport.swift`](../../Sources/SceneItCore/Format/ReviewReport.swift),
[`Sources/SceneItCore/Format/Typography.swift`](../../Sources/SceneItCore/Format/Typography.swift),
[`Sources/SceneItCore/Format/ReviewHTML.swift`](../../Sources/SceneItCore/Format/ReviewHTML.swift),
[`Sources/SceneItCore/Format/ReviewPlainText.swift`](../../Sources/SceneItCore/Format/ReviewPlainText.swift),
[`Sources/SceneItCore/Persistence/ChosenFileWrite.swift`](../../Sources/SceneItCore/Persistence/ChosenFileWrite.swift),
[`Sources/SceneItCore/Persistence/ReviewPageWriter.swift`](../../Sources/SceneItCore/Persistence/ReviewPageWriter.swift),
[`SceneIt/Books/ReviewOutput.swift`](../../SceneIt/Books/ReviewOutput.swift),
[`SceneItTests/ReviewOutputAppTests.swift`](../../SceneItTests/ReviewOutputAppTests.swift).

## 1. Build the report once, render it three times

The clipboard's HTML, its plain text and the saved page must say the same thing. Three functions
that each walk the review would each decide, separately, which scenes to include, how to order
comments and how much text to quote, and sooner or later they would disagree. So one pure
initializer makes a `ReviewReport`, and the three outputs only *render* it:

```swift
public struct ReviewReport: Hashable, Sendable {
    public let title: String
    public let day: CalendarDay
    public let notes: [ReportText]
    public let scenes: [Scene]
    …
    public init(_ review: Review, on day: CalendarDay) {
```

This is the Rust habit of parsing into an intermediate representation (an AST) and then running
several back ends over it. Every policy lives in the initializer: scenes with neither a comment nor
a note are dropped (`ReviewReport.includes`, which `Review.hasReport` uses too, so the menu's
enabled state can't disagree with the report), anchored comments are sorted by where their text
starts and ends, and each quote is cut from the scene's body plain text. The renderers,
`ReviewHTML.clipboard`, `ReviewHTML.page` and `ReviewPlainText.text`, decide only spelling.

The page goes one step further: its body *is* the clipboard HTML, built by the same function with
one switch:

```swift
enum ItemBox {
    case symbol, checkbox
}

static func body(_ report: ReviewReport, look: ReviewLook, box: ItemBox) -> String {
```

That's a two-case enum rather than a `Bool` parameter (the project's rule), and it makes the spec's
"the page's body is the clipboard's, byte for byte, with one substitution" a structural fact rather
than something tests have to catch.

The day is a parameter, not `Date.now` read inside, so the report is a pure function of its inputs
and the worked example in the spec is a golden test
(`Tests/Corpus/review-output/s8-worked-example`).

## 2. Smartening in two passes over different extents

Stored text is strict ASCII (ADR 0028), so curly quotes and dashes appear only in the output. The
spec's rule is subtle: a quote's direction is decided over a whole *unit* (a paragraph), but `--`
and `...` are replaced only within a *piece* (the part before the passage, the passage, the part
after) and within a run of one style. A quote at the very start of a passage still opens correctly,
because it saw the paragraph's text before it.

`SmartUnit` does this in two passes. Its initializer turns the quotes over the whole unit, one
output scalar per input scalar, so offsets still line up; `piece(_:)` then replaces dash and dot
runs inside a range only:

```swift
struct SmartUnit {
    private let scalars: [Unicode.Scalar]

    init(_ text: String) {
        scalars = Self.turningQuotes(Array(text.unicodeScalars))
    }

    func piece(_ range: Range<Int>) -> String {
```

Working on `[Unicode.Scalar]` rather than `String` is the Swift equivalent of working on a `Vec<u8>`
when you know the text is ASCII: `String`'s indices are opaque grapheme positions, so integer
offsets need an array. The elision list and the characters a quote opens after are `static let`
sets, data in one place, as the spec asks. A property test checks that ADR 0028's transliteration
table turns every smartened string back into exactly its input.

## 3. Escaping is the renderer's only job

The HTML is ASCII: `&`, `<`, `>` and `"` become entities, and every scalar above U+007E becomes a
hexadecimal reference (`&#x2019;`), so no clipboard or mail client can garble the encoding.
`ReviewHTML.escaped` is the one function every piece of text passes through, which is why the tests
can put `</p><script>` in a comment and `<Jerry>` in a title and expect them back as text.

## 4. A shared write with typed throws

Export as SceneIt… ([chapter 07d](07d-export-as-sceneit.md)) already wrote to a place the writer
chose: check what's there, write a hidden temporary file, rename it into place. Save Review… needs
the same steps, so they moved into `ChosenFileWrite`, which now also reads the temporary file back
before the rename. Each caller keeps its own error type and maps the helper's:

```swift
do throws(ChosenFileFailure) {
    try ChosenFileWrite.write(Data(page.utf8), to: destination, fileSystem: fileSystem)
} catch {
    throw .destination(error)
}
```

`do throws(T)` is Swift's typed throws: inside the block `error` is a `ChosenFileFailure`, not
`any Error`, much like a `Result<_, ChosenFileFailure>` with `map_err` in Rust. `SaveReviewFailure`
wraps it as a case (`.destination`), which keeps the export's existing `ExportFailure` unchanged.

Save Review… adds two guards of its own before writing: the destination must be named `.html` (so
it can never be the copy, a `.review.md` or one of the review's backups), and it mustn't be the copy
under another name (compared by file identity, which catches hard and symbolic links) or inside the
folder where the review's backups and lock live.

## 5. The pasteboard holds several representations at once

A copy on macOS can offer the same content in several types; the app you paste into picks the
richest it understands. Copy Review declares two and fills both:

```swift
pasteboard.declareTypes([.html, .string], owner: nil)
pasteboard.setString(ReviewHTML.clipboard(report), forType: .html)
pasteboard.setString(ReviewPlainText.text(report), forType: .string)
```

Gmail and Mail take `public.html`; a plain-text editor takes the string. The pasteboard is a seam on
`BookController`: `.general` in the app, `NSPasteboard.withUniqueName()` in the test host, so a test
never replaces what the owner copied.

## 6. WebKit in a hosted test

The saved page has a script that remembers ticks in `localStorage`. To test it as a browser runs
it, `ReviewPageWebTests` loads the page into a `WKWebView` in an offscreen window, waits for the
navigation delegate's `didFinish` through a checked continuation (the async bridge for a callback
API, like a oneshot channel in Rust), then asks questions with `evaluateJavaScript`: how many
checkboxes, is the clicked one dimmed, and is it still ticked after a reload. The web view's data
store is `.nonPersistent()`, so nothing is written to disk. The page is loaded with an `https:` base
URL that's never fetched (the page's Content-Security-Policy forbids any fetch anyway), because
WebKit gives a page with no origin no storage.

The same web view draws the look candidates: `takeSnapshot(configuration:)` renders the page to an
image without reading the screen.

## What isn't automated

Pasting into Gmail and Mail can't be tested here: it needs a real compose window. That's a manual
check for the owner.
