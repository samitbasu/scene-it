import AppKit
import Testing

@testable import SceneItCore

/// The two editors the codec serves; every behaviour is the same for both.
enum Editor: CaseIterable, Sendable {
    case body, notes

    @MainActor
    func load(_ paragraphs: [Paragraph]) -> NSAttributedString {
        switch self {
        case .body: RunCodec.attributedString(forBody: paragraphs)
        case .notes: RunCodec.attributedString(forNotes: paragraphs)
        }
    }

    @MainActor
    func save(_ text: NSAttributedString) -> [Paragraph] {
        switch self {
        case .body: RunCodec.body(from: text)
        case .notes: RunCodec.notes(from: text)
        }
    }

    @MainActor
    func roundTrip(_ paragraphs: [Paragraph]) -> [Paragraph] {
        save(load(paragraphs))
    }
}

@MainActor @Suite struct RunCodecTests {
    nonisolated private static let separators = [
        "\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}",
    ]

    @Test(arguments: Editor.allCases)
    func everyColorHighlightAndStyleCombinationRoundTrips(editor: Editor) {
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
        #expect(editor.roundTrip([Paragraph(runs)]) == [Paragraph(runs)])
    }

    @Test(arguments: Editor.allCases)
    func overlappingCommentsRoundTrip(editor: Editor) {
        let (a, b, c) = (CommentID(rawValue: "a"), CommentID(rawValue: "b"), CommentID(rawValue: "c"))
        let paragraphs: [Paragraph] = [
            [
                Run("one "), Run("two ", comments: [a]), Run("three ", comments: [a, b]),
                Run("four", comments: [b]),
            ],
            [Run("five", styles: [.italic], comments: [a, b, c]), Run(" six", comments: [c])],
        ]
        #expect(editor.roundTrip(paragraphs) == paragraphs)
    }

    @Test(arguments: Editor.allCases)
    func emptyParagraphsHaveNoRunsAndRoundTrip(editor: Editor) {
        let paragraphs: [Paragraph] = [[], [Run("text")], [], []]
        #expect(editor.load(paragraphs).string == "\ntext\n\n")
        #expect(editor.roundTrip(paragraphs) == paragraphs)
        #expect(editor.roundTrip([[], []]) == [[], []])
    }

    @Test(arguments: Editor.allCases)
    func emptyTextIsNoParagraphs(editor: Editor) {
        #expect(editor.save(NSAttributedString()) == [])
        #expect(editor.roundTrip([]) == [])
        #expect(editor.roundTrip([[]]) == [], "one empty paragraph is indistinguishable from none")
    }

    @Test(arguments: Editor.allCases, separators)
    func everySeparatorEndsAParagraph(editor: Editor, separator: String) {
        let text = NSAttributedString(string: "zero\(separator)one\(separator)\(separator)two")
        #expect(editor.save(text) == [[Run("zero")], [Run("one")], [], [Run("two")]])
    }

    @Test func aCarriageReturnLineFeedIsOneBreakEvenAcrossAttributeRuns() {
        let text = NSMutableAttributedString(string: "a\r", attributes: [.strikethroughStyle: 1])
        text.append(NSAttributedString(string: "\nb"))
        #expect(RunCodec.body(from: text) == [[Run("a", styles: [.strike])], [Run("b")]])
    }

    @Test func savingMergesAdjacentRunsWithTheSameFormat() {
        let text = NSMutableAttributedString(
            attributedString: RunCodec.attributedString(forBody: [[Run("abc")]]))
        text.addAttribute(.link, value: "https://example.com", range: NSRange(location: 1, length: 1))
        #expect(RunCodec.body(from: text) == [[Run("abc")]])
        #expect(
            RunCodec.body(from: RunCodec.attributedString(forBody: [[Run("a"), Run("b")]])) == [[Run("ab")]])
    }

    @Test func foreignAttributesAreDropped() throws {
        let helvetica = try #require(NSFont(name: "Helvetica", size: 30))
        let foreign: [NSAttributedString.Key: Any] = [
            .font: helvetica,
            .link: try #require(URL(string: "https://example.com")),
            .underlineStyle: NSUnderlineStyle.double.rawValue,
            .kern: 3,
            .shadow: NSShadow(),
            .paragraphStyle: NSParagraphStyle.default,
            .init("com.example.custom"): "x",
        ]
        let text = NSAttributedString(string: "pasted", attributes: foreign)
        #expect(RunCodec.body(from: text) == [[Run("pasted")]])
    }

    @Test func pastedBoldAndItalicFontsKeepTheirStyle() throws {
        let font = try #require(NSFont(name: "Helvetica-BoldOblique", size: 30))
        try #require(font.fontDescriptor.symbolicTraits.isSuperset(of: [.bold, .italic]))
        let text = NSAttributedString(string: "pasted", attributes: [.font: font])
        #expect(RunCodec.body(from: text) == [[Run("pasted", styles: [.bold, .italic])]])
    }

    @Test func aColorWithoutAPaletteNameMapsToNoColor() {
        let text = NSAttributedString(
            string: "pasted",
            attributes: [
                .foregroundColor: PaletteColor.red.nsColor, .backgroundColor: HighlightColor.blue.nsColor,
            ])
        #expect(RunCodec.body(from: text) == [[Run("pasted")]])
    }

    @Test func thePaletteNameWinsOverTheNSColor() {
        let text = NSMutableAttributedString(
            attributedString: RunCodec.attributedString(forBody: [[Run("x", color: .red, highlight: .green)]])
        )
        text.addAttributes(
            [.foregroundColor: NSColor.systemBlue, .backgroundColor: NSColor.systemYellow],
            range: NSRange(location: 0, length: 1))
        #expect(RunCodec.body(from: text) == [[Run("x", color: .red, highlight: .green)]])
    }

    @Test func malformedNovelAttributesAreDropped() {
        let text = NSAttributedString(
            string: "x",
            attributes: [
                .textColor: "black", .highlight: "chartreuse", .comments: NSSet(array: [NSNumber(value: 1)]),
            ])
        #expect(RunCodec.body(from: text) == [[Run("x")]])
    }

    @Test(arguments: Editor.allCases)
    func attachmentsAreRemoved(editor: Editor) {
        let text = NSMutableAttributedString(string: "ab")
        text.append(NSAttributedString(attachment: NSTextAttachment()))
        text.append(NSAttributedString(string: "cd"))
        #expect(text.string.contains("\u{FFFC}"), "precondition: an attachment is U+FFFC in the text")
        #expect(editor.save(text) == [[Run("abcd")]])
    }

    @Test func aLoneSurrogateBecomesTheReplacementCharacter() {
        let units: [unichar] = [0x61, 0xD83D, 0x62]
        let lone = NSString(characters: units, length: units.count)
        #expect(lone.length == 3, "precondition: NSString holds the lone surrogate")
        let saved = RunCodec.body(from: NSAttributedString(string: lone as String))
        #expect(saved == [[Run("a\u{FFFD}b")]])
    }

    @Test func aRunBoundaryInsideASurrogatePairKeepsTheTextIntact() {
        let text = NSMutableAttributedString(string: "a😀b")
        text.addAttribute(.strikethroughStyle, value: 1, range: NSRange(location: 1, length: 1))
        let body = RunCodec.body(from: text)
        #expect(body.map(\.text) == ["a😀b"])
        #expect(body.allSatisfy { $0.runs.allSatisfy { !$0.text.isEmpty } })
    }

    @Test func offsetsCountUTF16CodeUnits() {
        let body: [Paragraph] = [[Run("😀")], [Run("é", styles: [.bold])]]
        let text = RunCodec.attributedString(forBody: body)
        #expect(text.length == 4, "😀 is two UTF-16 code units; é is one; plus the break")
        #expect(text.string.count == 3)
        #expect(RunCodec.body(from: text) == body)
    }

    @Test(arguments: 0..<100)
    func generatedScenesRoundTrip(seed: UInt64) {
        var generator = BookGenerator(seed: seed)
        var book = generator.book()
        for list in [\Book.scenes, \Book.boneyard] {
            for index in book[keyPath: list].indices {
                let scene = book[keyPath: list][index]
                for (editor, part) in [(Editor.body, \BookScene.body), (.notes, \BookScene.notes)] {
                    let original = scene[keyPath: part]
                    let saved = editor.roundTrip(original)
                    #expect(Self.characters(saved) == Self.characters(original == [[]] ? [] : original))
                    #expect(saved.allSatisfy(Self.isCanonical))
                    #expect(editor.roundTrip(saved) == saved, "idempotent")
                    book[keyPath: list][index][keyPath: part] = saved
                }
            }
        }
        #expect(BookValidator.problems(in: book).isEmpty)
    }

    @Test func randomSeparatorsAndForeignAttributesSaveToValidParagraphs() {
        var random = SplitMix64(seed: 14)
        let pieces = ["a", "é", "😀", "\u{FFFC}"] + Self.separators
        let attributes: [[NSAttributedString.Key: Any]] = [
            [:], [.underlineStyle: 1], [.textColor: "red"], [.strikethroughStyle: 1],
            [.font: ParagraphRole.body.font([.bold])], [.comments: NSSet(array: ["c1"])],
            [.attachment: NSTextAttachment()],
        ]
        for _ in 0..<200 {
            let text = NSMutableAttributedString()
            for _ in 0..<Int.random(in: 0...20, using: &random) {
                text.append(
                    NSAttributedString(
                        string: pieces.randomElement(using: &random)!,
                        attributes: attributes.randomElement(using: &random)!))
            }
            let body = RunCodec.body(from: text)
            #expect(body.allSatisfy(Self.isCanonical))
            #expect(RunCodec.body(from: RunCodec.attributedString(forBody: body)) == body, "idempotent")
            var expected = ""
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
                let piece = text.attributedSubstring(from: range).string
                expected += attributes[.attachment] == nil ? piece : piece.replacing("\u{FFFC}", with: "")
            }
            let scalars = expected.unicodeScalars.filter { !Character($0).isNewline }
            #expect(Array(body.map(\.text).joined().unicodeScalars) == Array(scalars))
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
