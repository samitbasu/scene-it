import AppKit
import Testing

@testable import SceneItCore

@Suite(.timeLimit(.minutes(2))) struct BodyChangeTests {
    /// Every piece an edit might insert, line breaks of every kind among them.
    private static let pieces = [
        "a", "word ", "é", "\n", "\r\n", "\r", "\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}",
        "\u{FFFC}", "\u{1F30A}", "",
    ]

    private static func random(_ count: Int, using random: inout SplitMix64) -> String {
        (0..<count).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }.joined()
    }

    @Test func aRangedChangeGivesWhatConvertingTheWholeTextGives() throws {
        var random = SplitMix64(seed: 15)
        for round in 0..<3000 {
            let before = Self.random(Int(random.next() % 12), using: &random)
            let text = NSTextStorage(string: before, attributes: ParagraphRole.body.typingAttributes)
            let body = RunCodec.body(from: text)
            let length = text.length
            let start = Int(random.next() % UInt64(length + 1))
            let end = start + Int(random.next() % UInt64(length - start + 1))
            let inserted = Self.random(Int(random.next() % 4), using: &random)
            let replacement = NSAttributedString(
                string: inserted,
                attributes: ParagraphRole.body.typingAttributes(continuing: [
                    .font: ParagraphRole.body.font(round.isMultiple(of: 2) ? [.bold] : [])
                ]))
            text.replaceCharacters(in: NSRange(location: start, length: end - start), with: replacement)
            let edited = NSRange(location: start, length: replacement.length)

            let change = try #require(
                RunCodec.bodyChange(edited: edited, in: text, linesBefore: BodyChange.lineCount(of: body)),
                "round \(round) \(Array(before.unicodeScalars).map { String($0.value, radix: 16) }) start \(start) end \(end) inserted \(Array(inserted.unicodeScalars).map { String($0.value, radix: 16) })"
            )
            #expect(
                change.applied(to: body) == RunCodec.body(from: text),
                "round \(round): \(before.debugDescription)")
        }
    }

    @Test func typingConvertsOnlyTheParagraphTyped() throws {
        let body: [Paragraph] = [[Run("One.")], [Run("Two.")], [Run("Three.")]]
        let text = NSMutableAttributedString(attributedString: RunCodec.attributedString(forBody: body))
        text.insert(NSAttributedString(string: "!"), at: 8)
        let change = try #require(
            RunCodec.bodyChange(edited: NSRange(location: 8, length: 1), in: text, linesBefore: 3))
        #expect(change == BodyChange(lines: 1..<2, paragraphs: [[Run("Two!.")]]))
    }

    @Test func returnSplitsOneLineIntoTwo() throws {
        let text = NSMutableAttributedString(string: "Onetwo")
        text.insert(NSAttributedString(string: "\n"), at: 3)
        let change = try #require(
            RunCodec.bodyChange(edited: NSRange(location: 3, length: 1), in: text, linesBefore: 1))
        #expect(change == BodyChange(lines: 0..<1, paragraphs: [[Run("One")], [Run("two")]]))
    }

    @Test func aLineCountThatCantBeRightIsRefused() {
        let text = NSAttributedString(string: "a\nb\nc")
        #expect(RunCodec.bodyChange(edited: NSRange(location: 0, length: 1), in: text, linesBefore: 1) == nil)
        #expect(RunCodec.bodyChange(edited: NSRange(location: 4, length: 9), in: text, linesBefore: 3) == nil)
    }

    @Test func anEmptyBodyIsOneEmptyLine() {
        #expect(BodyChange.lineCount(of: []) == 1)
        #expect(BodyChange(lines: 0..<1, paragraphs: [[Run("x")]]).applied(to: []) == [[Run("x")]])
        #expect(BodyChange(lines: 0..<1, paragraphs: [[]]).applied(to: [[Run("x")]]) == [])
        #expect(BodyChange(lines: 0..<2, paragraphs: [[]]).applied(to: []) == nil)
    }

    @Test func typingAfterCommentedTextNeverCarriesTheComment() {
        let commented = RunCodec.attributedString(forBody: [
            [
                Run(
                    "noted", styles: [.italic], color: .blue, highlight: .green,
                    comments: [CommentID(rawValue: "c1")])
            ]
        ])
        let typing = ParagraphRole.body.typingAttributes(
            continuing: commented.attributes(at: 4, effectiveRange: nil))
        let typed = RunCodec.body(from: NSAttributedString(string: "x", attributes: typing))
        #expect(typed == [[Run("x", styles: [.italic], color: .blue, highlight: .green)]])
        #expect(typing[.comments] == nil)
    }

    @Test func inputIsAdmittedWithoutAttachments() {
        #expect(
            CharacterPolicy.admittedInput("“Hi”—\u{FFFC}\u{1F30A}\u{2028}é\r\nΩ") == "\"Hi\"--[?]\né\n[?]")
    }
}
