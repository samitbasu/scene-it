import Foundation
import Testing

@testable import SceneItCore

/// Copy Review's HTML and plain text, and Save Review…'s page (review format §5–§8): the worked
/// example byte for byte, the appendix's C1 and C2 vectors, and what the outputs must never hold.
struct ReviewOutputTests {
    static let example = "review-output/s8-worked-example"

    static func corpus(_ file: String) throws -> String {
        let root = try #require(Corpus.root, "the corpus isn't in the test bundle")
        return String(
            decoding: try Data(contentsOf: root.appending(path: "\(example)/\(file)")), as: UTF8.self)
    }

    /// The worked example's review, its review id, and the day it was copied.
    static func workedExample() throws -> (ReviewReport, ReviewID) {
        let copy = try ReviewFormatTests.received(try corpus("copy.md"))
        let parsed = try ReviewFormatTests.parse(try corpus("review.md"), against: copy)
        try #require(parsed.newEntries.isEmpty, "precondition: §8.2 is canonical")
        let copied = try #require(Timestamp(try corpus("copied-at.txt").trimmingCharacters(in: .newlines)))
        let zone = try #require(TimeZone(secondsFromGMT: copied.offset.minutes * 60))
        return (ReviewReport(parsed.review, on: CalendarDay(copied.date, in: zone)), parsed.review.id)
    }

    // MARK: The worked example (§8, appendix C3)

    @Test func theWorkedExamplesHTMLIsSection8Point3() throws {
        let (report, _) = try Self.workedExample()
        #expect(ReviewHTML.clipboard(report) == (try Self.corpus("expected.html")))
    }

    @Test func theWorkedExamplesPlainTextIsSection8Point4() throws {
        let (report, _) = try Self.workedExample()
        #expect(ReviewPlainText.text(report) == (try Self.corpus("expected.txt")))
    }

    @Test func theWorkedExamplesPageIsSection8Point5() throws {
        let (report, id) = try Self.workedExample()
        #expect(ReviewHTML.page(report, review: id) == (try Self.corpus("expected-standalone.html")))
    }

    @Test func thePagesBodyIsTheClipboardsWithACheckboxForEachBox() throws {
        let (report, id) = try Self.workedExample()
        let clipboard = ReviewHTML.clipboard(report)
        var expected = clipboard
        for item in report.items {
            let box = try #require(expected.range(of: "&#x2610; "))
            expected.replaceSubrange(
                box,
                with: "<input type=\"checkbox\" data-item=\"\(item.key)\" aria-label=\"Done\" "
                    + "style=\"margin:0 8px 0 0;\">")
        }
        try #require(report.items.count == 3, "precondition: the example has three items")
        #expect(ReviewHTML.page(report, review: id).contains(expected))
    }

    @Test func theClipboardHTMLIsASCIIWithInlineStylesOnly() throws {
        let (report, id) = try Self.workedExample()
        let html = ReviewHTML.clipboard(report)
        #expect(html.utf8.allSatisfy { $0 < 0x7F })
        #expect(ReviewHTML.page(report, review: id).utf8.allSatisfy { $0 < 0x7F })
        for forbidden in ["<style", "class=", "id=", "<table", "<h1", "<blockquote", "<ul", "<form"] {
            #expect(!html.contains(forbidden), "\(forbidden)")
        }
        #expect(Set(HTMLShape.elements(in: html)) == ["div", "p", "span", "b", "i"])
    }

    /// C3: every character of body text in the output is in a paragraph some comment quotes.
    @Test func theOutputHoldsNoBodyTextButTheQuotedParagraphs() throws {
        let copy = try ReviewFormatTests.received(try Self.corpus("copy.md"))
        let (report, id) = try Self.workedExample()
        let outputs = [
            ReviewPlainText.text(report), ReviewHTML.clipboard(report), ReviewHTML.page(report, review: id),
        ]
        let quoted = Set(
            report.items.compactMap(\.quote).map { $0.before.plain + $0.passage.plain + $0.after.plain })
        let unquoted = copy.book.scenes.flatMap(\.body).map { Typography.smartened($0.text) }
            .filter { !quoted.contains($0) }
        try #require(unquoted.count == 2, "precondition: two of the copy's paragraphs have no comment")
        for paragraph in unquoted {
            for output in outputs {
                #expect(!Self.decoded(output).contains(paragraph))
                #expect(!Self.decoded(output).contains(paragraph.prefix(20)))
            }
        }
    }

    // MARK: What the report holds (§5.1)

    @Test func scenesWithNeitherACommentNorANoteAreLeftOut() {
        let review = Self.review([
            Self.scene("s1", "Kept", ["Nobody here."], notes: ["A note."]),
            Self.scene("s2", "Dropped", ["Secret middle paragraph."]),
        ])
        let report = ReviewReport(review, on: Self.day)
        #expect(report.scenes.map(\.title) == ["Kept"])
        #expect(!ReviewPlainText.text(report).contains("Dropped"))
        #expect(!ReviewPlainText.text(report).contains("Secret"))
        #expect(!ReviewPlainText.text(report).contains("Nobody here"), "a note quotes nothing")
    }

    @Test func anEmptyReviewHasNoReport() {
        let review = Self.review([Self.scene("s1", "Dawn", ["The ferry left at dawn."])])
        #expect(!review.hasReport)
        #expect(ReviewReport(review, on: Self.day).isEmpty)
        var noted = review
        noted.notes = [[Run("General.")]]
        #expect(noted.hasReport)
    }

    @Test func onlyTheCommentedParagraphIsQuoted() {
        let review = Self.review([
            Self.scene(
                "s1", "Dawn", ["Alpha opening line.", "Bravo middle line.", "Charlie closing line."],
                comments: [("c1", [26..<32], "Why?")])
        ])
        let report = ReviewReport(review, on: Self.day)
        let outputs = [
            ReviewPlainText.text(report), ReviewHTML.clipboard(report),
            ReviewHTML.page(report, review: ReviewID(rawValue: "r81")),
        ]
        #expect(outputs[0].contains("\u{2610} Bravo [middle] line.\n    Why?\n"))
        for output in outputs {
            #expect(output.contains("middle"))
            #expect(!output.contains("Alpha") && !output.contains("Charlie"))
        }
    }

    @Test func itemsAreInTextOrderThenDetachedOnesInModelOrder() {
        let review = Self.review([
            Self.scene(
                "s1", "Dawn", ["One two three four."],
                comments: [
                    ("late", [8..<13], "third"), ("loose", [], "detached first"), ("wide", [0..<7], "second"),
                    ("early", [0..<3], "first"), ("free", [], "detached second"),
                ])
        ])
        let items = ReviewReport(review, on: Self.day).items
        #expect(items.map(\.key.comment.rawValue) == ["early", "wide", "late", "loose", "free"])
        #expect(items.map { $0.quote == nil } == [false, false, false, true, true])
    }

    @Test func anUntitledSceneIsShownAsSuch() {
        let review = Self.review([Self.scene("s1", "", ["Text."], notes: ["Note."])])
        let report = ReviewReport(review, on: Self.day)
        #expect(report.scenes.map(\.title) == [ReviewOutputWording.untitledScene])
        #expect(ReviewPlainText.text(report).contains("(untitled scene)\n----------------\n"))
    }

    @Test func emptyParagraphsAndLineBreaksInComments() {
        let review = Self.review([
            Self.scene(
                "s1", "Dawn", ["Words here."], notes: ["First.", "", "Third."],
                comments: [("c1", [0..<5], "Line one.\nLine two."), ("c2", [], "Whole\nscene.")])
        ])
        let report = ReviewReport(review, on: Self.day)
        let text = ReviewPlainText.text(report)
        #expect(text.contains("\u{2610} [Words] here.\n    Line one.\n    Line two.\n"))
        #expect(text.contains("\u{2610} Whole\n    scene.\n"))
        #expect(text.contains("First.\n\n\n\nThird.\n"), "an empty paragraph: three blank lines in a row")
        let html = ReviewHTML.clipboard(report)
        #expect(html.contains("<p style=\"margin:4px 0 0 28px;\">Line one.<br>Line two.</p>"))
        #expect(html.contains("<p style=\"margin:0;\">&#x2610; Whole<br>scene.</p>"))
        #expect(html.contains("<p style=\"margin:0 0 8px 0;\"><br></p>"))
    }

    @Test func aCommentWithNoTextShowsOnlyItsQuote() {
        let review = Self.review([Self.scene("s1", "Dawn", ["Words here."], comments: [("c1", [0..<5], "")])])
        let report = ReviewReport(review, on: Self.day)
        #expect(ReviewPlainText.text(report).contains("\u{2610} [Words] here.\n"))
        #expect(!ReviewHTML.clipboard(report).contains("28px"))
    }

    @Test func stylesNestBoldItalicThenStrikethrough() {
        var scene = Self.scene("s1", "Dawn", [""], comments: [("c1", [], "x")])
        scene.body = [
            [
                Run("all", styles: [.bold, .italic, .strike], comments: [CommentID(rawValue: "c1")]),
                Run(" plain"),
            ]
        ]
        scene.comments = [Comment(id: CommentID(rawValue: "c1"), color: .red, text: "", created: Self.time)]
        let html = ReviewHTML.clipboard(ReviewReport(Self.review([scene]), on: Self.day))
        #expect(
            html.contains(
                "<span style=\"background-color:#FFF2A8;\"><b><i><span style=\"text-decoration:line-through;\">"
                    + "all</span></i></b></span><span style=\"color:#666666;\"> plain</span>"))
    }

    @Test func theDateIsWrittenInEnglish() throws {
        #expect(
            ReviewOutputWording.date(try #require(CalendarDay(year: 2026, month: 1, day: 9)))
                == "January 9, 2026")
        #expect(ReviewOutputWording.date(Self.day) == "November 4, 2026")
    }

    // MARK: Quoted paragraphs (§5.2, appendix C2)

    static let rained = "It rained.\nShe left at once."

    @Test(arguments: [
        (
            #"He stopped. Mr. Grant waved. "Come in!" she said. Nobody moved."#, [22..<27],
            "He stopped. Mr. Grant [waved]. \u{201C}Come in!\u{201D} she said. Nobody moved."
        ),
        (
            #"He stopped. Mr. Grant waved. "Come in!" she said. Nobody moved."#, [40..<48],
            "He stopped. Mr. Grant waved. \u{201C}Come in!\u{201D} [she said]. Nobody moved."
        ),
        (
            #"He stopped. Mr. Grant waved. "Come in!" she said. Nobody moved."#, [30..<37],
            "He stopped. Mr. Grant waved. \u{201C}[Come in]!\u{201D} she said. Nobody moved."
        ),
        ("First paragraph.\nSecond one here.", [24..<27], "Second [one] here."),
        (rained, [3..<14], "It [rained. \u{00B6} She] left at once."),
        ("It rained.\nShe left.", [10..<14], "[She] left."),
        ("It rained.\nShe left.", [3..<11], "It [rained.]"),
        ("The ferry left at dawn.", [4..<9, 18..<22], "The [ferry left at dawn]."),
        ("One.\nTwo words.\nThree.", [9..<14], "Two [words]."),
        ("Wait -- what?", [5..<6], "Wait [-]- what?"),
    ])
    func c2QuotedParagraphs(text: String, ranges: [Range<Int>], shown: String) {
        let review = Self.review([
            Self.scene("s1", "Dawn", text.components(separatedBy: "\n"), comments: [("c1", ranges, "")])
        ])
        let quote = ReviewReport(review, on: Self.day).items.first?.quote
        #expect(quote.map { $0.before.plain + "[" + $0.passage.plain + "]" + $0.after.plain } == shown)
    }

    @Test func eachCommentOnOneParagraphQuotesItInFull() {
        let review = Self.review([
            Self.scene(
                "s1", "Dawn", ["Alpha beta gamma."], comments: [("c1", [0..<5], "a"), ("c2", [11..<16], "b")])
        ])
        let text = ReviewPlainText.text(ReviewReport(review, on: Self.day))
        #expect(text.contains("\u{2610} [Alpha] beta gamma.\n    a\n"))
        #expect(text.contains("\u{2610} Alpha beta [gamma].\n    b\n"))
    }

    // MARK: Smartening (§5.3, appendix C1)

    @Test(arguments: [
        (
            #""Don't look back," the deckhand said -- and she didn't."#,
            "\u{201C}Don\u{2019}t look back,\u{201D} the deckhand said \u{2014} and she didn\u{2019}t."
        ),
        (
            #"'Tis the '90s, rock 'n' roll... "'Hi,' she said." Wait-- "Go!""#,
            "\u{2019}Tis the \u{2019}90s, rock \u{2019}n\u{2019} roll\u{2026} \u{201C}\u{2018}Hi,\u{2019} she said.\u{201D} "
                + "Wait\u{2014} \u{201C}Go!\u{201D}"
        ),
        (
            #"He said "no"--"yes." ---- dashes. ...."#,
            "He said \u{201C}no\u{201D}\u{2014}\u{201C}yes.\u{201D} ---- dashes. \u{2026}."
        ),
        ("the boys' boat", "the boys\u{2019} boat"),
        (#"("quoted")"#, "(\u{201C}quoted\u{201D})"),
    ])
    func c1Smartening(input: String, output: String) {
        #expect(Typography.smartened(input) == output)
        #expect(Self.transliterated(output) == input)
    }

    /// Smartening is undone by ADR 0028's table, for every input.
    @Test func transliterationUndoesSmartening() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array(#"ab09 '"-.(/[{nNtTeEmisw"#)
        for _ in 0..<2000 {
            let input = String(
                (0..<Int.random(in: 0...24, using: &generator)).map { _ in
                    alphabet.randomElement(using: &generator)!
                })
            #expect(Self.transliterated(Typography.smartened(input)) == input, "\(input)")
        }
    }

    // MARK: Escaping and safety (§6.1, §7)

    @Test func markupInTitlesCommentsAndTextIsEscaped() {
        var review = Self.review(
            [
                Self.scene(
                    "s1", "<b>Bold</b> & \"so\"", ["a < b & c > d"],
                    comments: [("c1", [0..<1], "</p><script>alert(1)</script> & \"q\"")])
            ], title: "Tom & <Jerry>")
        review.notes = [[Run("<i>not</i> & \"x\"")]]
        let report = ReviewReport(review, on: Self.day)
        let html = ReviewHTML.clipboard(report)
        let page = ReviewHTML.page(report, review: review.id)
        #expect(html.contains("Review of Tom &amp; &lt;Jerry&gt;"))
        #expect(html.contains("&lt;b&gt;Bold&lt;/b&gt; &amp; &#x201C;so&#x201D;"))
        #expect(html.contains(" &lt; b &amp; c &gt; d"))
        #expect(html.contains("&lt;/p&gt;&lt;script&gt;alert(1)&lt;/script&gt; &amp; &#x201C;q&#x201D;"))
        #expect(html.contains("&lt;i&gt;not&lt;/i&gt; &amp; &#x201C;x&#x201D;"))
        #expect(!html.contains("<script") && !html.contains("<Jerry"))
        #expect(page.components(separatedBy: "<script").count == 2, "only the page's own script")
        #expect(page.contains("<title>Review of Tom &amp; &lt;Jerry&gt;</title>"))
        #expect(HTMLShape.check(html) == nil)
        #expect(HTMLShape.check(page) == nil)
    }

    @Test func escapingSpellsMarkupAndEverythingAboveASCIIAsReferences() {
        #expect(ReviewHTML.escaped("<&>\"'") == "&lt;&amp;&gt;&quot;'")
        #expect(ReviewHTML.escaped("\u{00B6}\u{2026}~\u{7F}") == "&#x00B6;&#x2026;~&#x007F;")
        #expect(ReviewHTML.escaped("\u{1F600}") == "&#x1F600;")
    }

    @Test func theOutputsParse() throws {
        let (report, id) = try Self.workedExample()
        for html in [ReviewHTML.clipboard(report), ReviewHTML.page(report, review: id)] {
            #expect(HTMLShape.check(html) == nil)
            let document = try XMLDocument(xmlString: html, options: [.documentTidyHTML])
            let text = try #require(document.rootElement()?.stringValue)
            #expect(text.contains("Lovely \u{2014} but is it too pretty for Mara\u{2019}s mood?"))
        }
        let page = try XMLDocument(
            xmlString: ReviewHTML.page(report, review: id), options: [.documentTidyHTML])
        #expect(try page.nodes(forXPath: "//input[@type='checkbox']").count == report.items.count)
    }

    @Test func checkboxKeysAreTheSceneAndCommentIdsAndStayPut() throws {
        let (report, id) = try Self.workedExample()
        let keys = [
            "01JCM9S346Q3D25VT4F5V37E3S/c1", "01JCM9S346Q3D25VT4F5V37E3S/c2", "01JC3E28JT97KB6CQ643DZVMXX/c1",
        ]
        #expect(HTMLShape.dataItems(in: ReviewHTML.page(report, review: id)) == keys)
        #expect(ReviewHTML.page(report, review: id) == ReviewHTML.page(report, review: id))

        let before = Self.review([
            Self.scene("s1", "Dawn", ["One two three."], comments: [("c7", [8..<13], "x")])
        ])
        let after = Self.review([
            Self.scene(
                "s1", "Dawn", ["One two three."], comments: [("c7", [8..<13], "x"), ("c8", [0..<3], "y")])
        ])
        #expect(
            HTMLShape.dataItems(in: ReviewHTML.page(ReviewReport(before, on: Self.day), review: before.id))
                == ["s1/c7"])
        #expect(
            HTMLShape.dataItems(in: ReviewHTML.page(ReviewReport(after, on: Self.day), review: after.id))
                == ["s1/c8", "s1/c7"], "a new comment doesn't change the others' keys")
    }

    @Test func theOutputsLoadNothingFromAnywhere() throws {
        let (report, id) = try Self.workedExample()
        let page = ReviewHTML.page(report, review: id)
        for html in [ReviewHTML.clipboard(report), page] {
            for reference in [
                "://", "src=", "href=", "url(", "@import", "<link", "<img", "<iframe", "srcset",
            ] {
                #expect(!html.contains(reference), "\(reference)")
            }
        }
        #expect(page.contains("content=\"default-src 'none';"))
    }

    @Test func thePageKeysTicksByTheReviewID() throws {
        let (report, id) = try Self.workedExample()
        #expect(
            ReviewHTML.page(report, review: id).contains(
                "var key = \"sceneit.review.01JDD8WQ4K7M2N9P3R5S6T8V0X\";"))
    }

    // MARK: Helpers

    static let time = Timestamp(Date(timeIntervalSince1970: 1_793_800_000), in: TimeZone(secondsFromGMT: 0)!)
    static let day = CalendarDay(year: 2026, month: 11, day: 4)!

    static func review(_ scenes: [BookScene], title: String = "Tide") -> Review {
        Review(
            book: Book(title: title, scenes: scenes), notes: [], copy: ExportID(rawValue: "e81"),
            id: ReviewID(rawValue: "r81"))
    }

    /// A scene whose body is `paragraphs`, with each comment on its ranges of the body's plain text
    /// (book format §3.6); a comment with no ranges is detached.
    static func scene(
        _ id: String, _ title: String, _ paragraphs: [String], notes: [String] = [],
        comments: [(String, [Range<Int>], String)] = []
    ) -> BookScene {
        var offset = 0
        let body = paragraphs.map { text in
            defer { offset += text.count + 1 }
            let covering = { (index: Int) in
                Set(
                    comments.filter { $0.1.contains { $0.contains(offset + index) } }.map {
                        CommentID(rawValue: $0.0)
                    })
            }
            var runs: [Run] = []
            for (index, character) in text.enumerated() {
                let ids = covering(index)
                if let last = runs.last, last.comments == ids {
                    runs[runs.count - 1].text.append(character)
                } else {
                    runs.append(Run(String(character), comments: ids))
                }
            }
            return Paragraph(runs)
        }
        return BookScene(
            id: SceneID(rawValue: id), modified: time, title: SceneTitle(title), body: body,
            notes: notes.map { $0.isEmpty ? Paragraph([]) : [Run($0)] },
            comments: comments.map {
                Comment(id: CommentID(rawValue: $0.0), color: .red, text: $0.2, created: time)
            })
    }

    static func transliterated(_ text: String) -> String {
        text.unicodeScalars.map { Transliteration.table[$0]?.ascii ?? String($0) }.joined()
    }

    /// `html`'s character references decoded, so its text can be searched.
    static func decoded(_ html: String) -> String {
        var text = html
        while let match = text.firstMatch(of: /&#x([0-9A-F]+);/) {
            let scalar = Unicode.Scalar(UInt32(match.output.1, radix: 16) ?? 0x3F) ?? "?"
            text.replaceSubrange(match.range, with: String(scalar))
        }
        return text
    }
}

/// A strict reading of the review's HTML: every tag well formed and closed in order (but the void
/// `br`, `input` and `meta`), every attribute value quoted, and no bare `<`, `>` or `&` in the text.
enum HTMLShape {
    static let void: Set<String> = ["br", "input", "meta", "!DOCTYPE"]

    /// `nil` if `html` is well formed; otherwise what's wrong.
    static func check(_ html: String) -> String? {
        var open: [String] = []
        var rest = Substring(html)
        let tag = /<(\/?)([!A-Za-z]+)((?:\s+[a-z-]+(?:="[^"<>]*")?)*)\s*>/
        let content = /[^<>&]*(?:&(?:amp|lt|gt|quot|#x[0-9A-F]{4,6});[^<>&]*)*/
        var inScript = false
        while !rest.isEmpty {
            if inScript {
                guard let end = rest.firstRange(of: "</script>") else { return "an unclosed script" }
                rest = rest[end.lowerBound...]
                inScript = false
            }
            if let match = rest.prefixMatch(of: tag) {
                let name = String(match.output.2)
                if match.output.1.isEmpty {
                    if !void.contains(name) { open.append(name) }
                    if name == "script" { inScript = true }
                } else {
                    guard open.popLast() == name else { return "</\(name)> closes the wrong element" }
                }
                rest = rest[match.range.upperBound...]
            } else if let match = rest.prefixMatch(of: content), !match.output.isEmpty {
                rest = rest[match.range.upperBound...]
            } else {
                return "unexpected text at \(rest.prefix(30))"
            }
        }
        return open.isEmpty ? nil : "unclosed \(open)"
    }

    static func elements(in html: String) -> [String] {
        html.matches(of: /<([a-z]+)[\s>]/).map { String($0.output.1) }
    }

    static func dataItems(in html: String) -> [String] {
        html.matches(of: /data-item="([^"]*)"/).map { String($0.output.1) }
    }
}
