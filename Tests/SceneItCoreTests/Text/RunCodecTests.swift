import AppKit
import Testing

@testable import SceneItCore

@MainActor @Suite struct RunCodecTests {
    private static let ids = (1...3).map { CommentID(rawValue: "c\($0)") }

    private static func roundTrip(_ page: ScenePage) -> ScenePage {
        RunCodec.page(from: RunCodec.attributedString(for: page))
    }

    private static func roundTrip(notes: [Paragraph]) -> [Paragraph] {
        RunCodec.notes(from: RunCodec.attributedString(forNotes: notes))
    }

    private static func page(_ text: NSAttributedString) -> ScenePage {
        RunCodec.page(from: text)
    }

    @Test func everyColorHighlightAndStyleCombinationRoundTrips() {
        let styleSets = TextStyle.allCases.reduce(into: [Set<TextStyle>()]) { sets, style in
            sets += sets.map { $0.union([style]) }
        }
        let colors: [TextColor?] = [nil] + TextColor.allCases
        let highlights: [HighlightColor?] = [nil] + HighlightColor.allCases
        var runs: [Run] = []
        for styles in styleSets {
            for color in colors {
                for highlight in highlights {
                    runs.append(Run("x", styles: styles, color: color, highlight: highlight))
                }
            }
        }
        #expect(runs.count == 8 * 7 * 7)
        #expect(Set(runs.map(RunFormat.init)).count == runs.count, "adjacent runs never merge")
        let page = ScenePage(title: [Run("Title")], body: [Paragraph(runs)])
        #expect(Self.roundTrip(page) == page)
        #expect(Self.roundTrip(notes: [Paragraph(runs)]) == [Paragraph(runs)])
    }

    @Test func overlappingCommentsRoundTrip() {
        let (a, b, c) = (Self.ids[0], Self.ids[1], Self.ids[2])
        let body: [Paragraph] = [
            [
                Run("one "), Run("two ", comments: [a]), Run("three ", comments: [a, b]),
                Run("four", comments: [b]),
            ],
            [Run("five", styles: [.italic], comments: [a, b, c]), Run(" six", comments: [c])],
        ]
        let page = ScenePage(title: [Run("Title", comments: [c])], body: body)
        #expect(Self.roundTrip(page) == page)
        #expect(Self.roundTrip(notes: body) == body)
    }

    @Test func emptyParagraphsHaveNoRunsAndRoundTrip() {
        let page = ScenePage(title: [], body: [[], [Run("text")], [], []])
        #expect(Self.roundTrip(page) == page)
        #expect(RunCodec.attributedString(for: page).string == "\n\ntext\n\n")
        #expect(
            Self.roundTrip(ScenePage(title: [Run("T")], body: [])) == ScenePage(title: [Run("T")], body: []))
        #expect(
            Self.roundTrip(ScenePage(title: [Run("T")], body: [[]]))
                == ScenePage(title: [Run("T")], body: [[]]))
        #expect(Self.page(NSAttributedString()) == ScenePage(title: [], body: []))
    }

    @Test func emptyNotesTextIsNoParagraphs() {
        #expect(Self.roundTrip(notes: []) == [])
        #expect(Self.roundTrip(notes: [[]]) == [], "one empty paragraph is no notes")
        #expect(Self.roundTrip(notes: [[], []]) == [[], []])
        #expect(Self.roundTrip(notes: [[Run("a")], []]) == [[Run("a")], []])
    }

    @Test func boldIsPartOfTheTitleSoTheTitleCannotCarryABoldStyle() {
        let page = ScenePage(
            title: [Run("Bold", styles: [.bold]), Run(" italic", styles: [.bold, .italic])], body: [])
        let saved = Self.roundTrip(page)
        #expect(saved.title == [Run("Bold"), Run(" italic", styles: [.italic])])
        let font =
            RunCodec.attributedString(for: page).attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font == ParagraphRole.title.font([]))
    }

    @Test(arguments: ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"])
    func everySeparatorEndsAParagraph(separator: String) {
        let text = NSAttributedString(string: "Title\(separator)one\(separator)\(separator)two")
        #expect(Self.page(text) == ScenePage(title: [Run("Title")], body: [[Run("one")], [], [Run("two")]]))
        #expect(RunCodec.notes(from: text) == [[Run("Title")], [Run("one")], [], [Run("two")]])
    }

    @Test func aCarriageReturnLineFeedIsOneBreakEvenAcrossAttributeRuns() {
        let text = NSMutableAttributedString(string: "a\r", attributes: [.strikethroughStyle: 1])
        text.append(NSAttributedString(string: "\nb"))
        #expect(RunCodec.notes(from: text) == [[Run("a", styles: [.strike])], [Run("b")]])
    }

    /// The moved text keeps the title font, so its bold, which was the heading's, becomes a style.
    @Test func aSeparatorInTheTitleStartsTheBody() {
        let page = ScenePage(title: [Run("Ti\u{2028}tle", styles: [.italic])], body: [[Run("Body")]])
        let saved = Self.roundTrip(page)
        #expect(
            saved
                == ScenePage(
                    title: [Run("Ti", styles: [.italic])],
                    body: [[Run("tle", styles: [.bold, .italic])], [Run("Body")]]))
        #expect(!saved.title.text.contains { $0.isNewline })
    }

    @Test func savingMergesAdjacentRunsWithTheSameFormat() {
        let text = NSMutableAttributedString(
            attributedString: RunCodec.attributedString(forNotes: [[Run("abc")]]))
        text.addAttribute(.link, value: "https://example.com", range: NSRange(location: 1, length: 1))
        #expect(RunCodec.notes(from: text) == [[Run("abc")]])
        #expect(
            RunCodec.notes(from: RunCodec.attributedString(forNotes: [[Run("a"), Run("b")]])) == [[Run("ab")]]
        )
    }

    @Test func foreignAttributesAreDropped() {
        let foreign: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Helvetica", size: 30) as Any,
            .link: URL(string: "https://example.com") as Any,
            .underlineStyle: NSUnderlineStyle.double.rawValue,
            .kern: 3,
            .shadow: NSShadow(),
            .paragraphStyle: NSParagraphStyle.default,
            .init("com.example.custom"): "x",
        ]
        #expect(NSFont(name: "Helvetica", size: 30) != nil)
        let text = NSAttributedString(string: "pasted", attributes: foreign)
        #expect(RunCodec.notes(from: text) == [[Run("pasted")]])
    }

    @Test func pastedBoldAndItalicFontsKeepTheirStyle() throws {
        let font = try #require(NSFont(name: "Helvetica-BoldOblique", size: 30))
        try #require(font.fontDescriptor.symbolicTraits.isSuperset(of: [.bold, .italic]))
        let text = NSAttributedString(string: "pasted", attributes: [.font: font])
        #expect(RunCodec.notes(from: text) == [[Run("pasted", styles: [.bold, .italic])]])
    }

    @Test func aColorWithoutAPaletteNameMapsToNoColor() {
        let text = NSAttributedString(
            string: "pasted",
            attributes: [
                .foregroundColor: PaletteColor.red.nsColor, .backgroundColor: HighlightColor.blue.nsColor,
            ])
        #expect(RunCodec.notes(from: text) == [[Run("pasted")]])
    }

    @Test func thePaletteNameWinsOverTheNSColor() {
        let text = NSMutableAttributedString(
            attributedString: RunCodec.attributedString(forNotes: [[Run("x", color: .red, highlight: .green)]]
            ))
        text.addAttributes(
            [.foregroundColor: NSColor.systemBlue, .backgroundColor: NSColor.systemYellow],
            range: NSRange(location: 0, length: 1))
        #expect(RunCodec.notes(from: text) == [[Run("x", color: .red, highlight: .green)]])
    }

    @Test func malformedNovelAttributesAreDropped() {
        let text = NSAttributedString(
            string: "x",
            attributes: [
                .textColor: "black", .highlight: "chartreuse", .comments: NSSet(array: [NSNumber(value: 1)]),
            ])
        #expect(RunCodec.notes(from: text) == [[Run("x")]])
    }

    @Test func aRunBoundaryInsideASurrogatePairKeepsTheTextIntact() {
        let text = NSMutableAttributedString(string: "a😀b")
        text.addAttribute(.strikethroughStyle, value: 1, range: NSRange(location: 1, length: 1))
        let notes = RunCodec.notes(from: text)
        #expect(notes.map(\.text) == ["a😀b"])
        #expect(notes.allSatisfy { $0.runs.allSatisfy { !$0.text.isEmpty } })
    }

    @Test func offsetsCountUTF16CodeUnits() {
        let page = ScenePage(title: [Run("😀")], body: [[Run("é", styles: [.bold])]])
        let text = RunCodec.attributedString(for: page)
        #expect(text.length == 4, "😀 is two UTF-16 code units; é is one; plus the break")
        #expect(text.string.count == 3)
        #expect(Self.roundTrip(page) == page)
    }

    @Test(arguments: 0..<100)
    func generatedScenesRoundTrip(seed: UInt64) {
        var generator = BookGenerator(seed: seed)
        var book = generator.book()
        for list in [\Book.scenes, \Book.boneyard] {
            for index in book[keyPath: list].indices {
                let scene = book[keyPath: list][index]
                let page = ScenePage(title: scene.title, body: scene.body)
                let savedPage = Self.roundTrip(page)
                let savedNotes = Self.roundTrip(notes: scene.notes)
                var expectedTitle = scene.title
                for run in expectedTitle.runs.indices {
                    expectedTitle.runs[run].styles.remove(.bold)
                }
                #expect(
                    Self.characters([savedPage.title] + savedPage.body)
                        == Self.characters([expectedTitle] + scene.body))
                #expect(
                    Self.characters(savedNotes) == Self.characters(scene.notes == [[]] ? [] : scene.notes))
                for paragraph in [savedPage.title] + savedPage.body + savedNotes {
                    #expect(Self.isCanonical(paragraph))
                }
                #expect(Self.roundTrip(savedPage) == savedPage, "idempotent")
                #expect(Self.roundTrip(notes: savedNotes) == savedNotes, "idempotent")
                book[keyPath: list][index].title = savedPage.title
                book[keyPath: list][index].body = savedPage.body
                book[keyPath: list][index].notes = savedNotes
            }
        }
        #expect(BookValidator.problems(in: book).isEmpty)
    }

    @Test func randomSeparatorsAndForeignAttributesSaveToValidParagraphs() {
        var random = SplitMix64(seed: 14)
        let pieces = [
            "a", "é", "😀", "\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}",
        ]
        let attributes: [[NSAttributedString.Key: Any]] = [
            [:], [.underlineStyle: 1], [.textColor: "red"], [.strikethroughStyle: 1],
            [.font: ParagraphRole.body.font([.bold])], [.comments: NSSet(array: ["c1"])],
        ]
        for _ in 0..<200 {
            let text = NSMutableAttributedString()
            for _ in 0..<Int.random(in: 0...20, using: &random) {
                text.append(
                    NSAttributedString(
                        string: pieces.randomElement(using: &random)!,
                        attributes: attributes.randomElement(using: &random)!))
            }
            let page = RunCodec.page(from: text)
            let paragraphs = [page.title] + page.body + RunCodec.notes(from: text)
            #expect(paragraphs.allSatisfy(Self.isCanonical))
            #expect(Self.roundTrip(page) == page, "idempotent")
            let expected = text.string.unicodeScalars.filter { !Character($0).isNewline }
            #expect(Array(([page.title] + page.body).map(\.text).joined().unicodeScalars) == Array(expected))
        }
    }

    /// Each paragraph as one single-scalar run per scalar, so run boundaries don't matter.
    private static func characters(_ paragraphs: [Paragraph]) -> [[Run]] {
        paragraphs.map { paragraph in
            paragraph.runs.flatMap { run in
                run.text.unicodeScalars.map { scalar in
                    var piece = run
                    piece.text = String(scalar)
                    return piece
                }
            }
        }
    }

    private static func isCanonical(_ paragraph: Paragraph) -> Bool {
        let runs = paragraph.runs
        return runs.allSatisfy { !$0.text.isEmpty && !$0.text.contains(where: \.isNewline) }
            && zip(runs, runs.dropFirst()).allSatisfy { RunFormat($0) != RunFormat($1) }
    }
}
