import AppKit
import Testing

@testable import SceneItCore

/// The body's double spacing sits below each line (ADR 0034) and moves no line of text from
/// where `lineHeightMultiple = 2`, which put it above, had it.
struct DoubleSpacingTests {
    /// TextKit lays a line out with its ascent and descent rounded up to whole points, and
    /// doubling adds that again; the gap is measured, and this pins what it comes to.
    @Test func theGapIsTheBodyFontsRoundedAscentAndDescent() {
        let font = ParagraphRole.body.font([])
        #expect(ParagraphRole.doubleSpacingGap == ceil(font.ascender) + ceil(-font.descender))
        #expect(ParagraphRole.doubleSpacingGap == 14, "for 12 pt Times New Roman")
        #expect(ParagraphRole.body.paragraphStyle.lineSpacing == ParagraphRole.doubleSpacingGap)
        #expect(ParagraphRole.body.paragraphStyle.lineHeightMultiple == 0)
    }

    /// Several pages of wrapped, bold and italic paragraphs with empty ones among them: every line,
    /// empty ones included, has the baseline it had with the multiple, once the text starts a gap
    /// lower.
    @Test func everyLineKeepsItsBaseline() throws {
        let long =
            "The ferry left before dawn, and nobody on the quay said a word about the letter that had "
            + "come for her in the night, though everyone had seen the boy run down the hill with it."
        let body: [Paragraph] = (0..<16).flatMap { round -> [Paragraph] in
            [
                [Run(long + " " + long)],
                [
                    Run("Plain then "), Run("bold words", styles: [.bold]), Run(" and "),
                    Run("italic ones", styles: [.italic, .bold]),
                    Run(" running on long enough to wrap onto the next line, round \(round)."),
                ],
                [],
                [Run("Short.")],
            ]
        }
        let shown = RunCodec.attributedString(forBody: body)
        let multiple = NSMutableAttributedString(attributedString: shown)
        let doubled = NSMutableParagraphStyle()
        doubled.setParagraphStyle(ParagraphRole.body.paragraphStyle)
        doubled.lineSpacing = 0
        doubled.lineHeightMultiple = 2
        multiple.addAttribute(
            .paragraphStyle, value: doubled, range: NSRange(location: 0, length: multiple.length))

        let now = try textLines(shown)
        let before = try textLines(multiple)
        try #require(now.count == before.count, "precondition: the same lines")
        try #require(now.count > 100, "precondition: several pages of lines")
        try #require(now.contains { $0.isWrapped }, "precondition: wrapped lines")
        try #require(now.contains { !$0.hasText && $0.range.length > 0 }, "precondition: empty paragraphs")
        for (line, old) in zip(now, before) where line.range.length > 0 {
            #expect(
                line.baseline + ParagraphRole.doubleSpacingGap == old.baseline, "line \(line.range)")
        }
        let last = try #require(now.last)
        let oldLast = try #require(before.last)
        #expect(
            last.bottom + ParagraphRole.doubleSpacingGap == oldLast.bottom,
            "the text ends where it did, so the page is as tall")
    }

    private struct LaidOutLine {
        let range: NSRange
        let baseline: CGFloat
        let bottom: CGFloat
        let hasText: Bool
        let isWrapped: Bool
    }

    private func textLines(_ text: NSAttributedString) throws -> [LaidOutLine] {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        layout.textContainer = NSTextContainer(
            size: NSSize(width: 468, height: CGFloat.greatestFiniteMagnitude))
        layout.textContainer?.lineFragmentPadding = 0
        content.attributedString = text
        let string = text.string as NSString
        var lines: [LaidOutLine] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
            fragment in
            let start = content.offset(
                from: content.documentRange.location, to: fragment.rangeInElement.location)
            for (index, line) in fragment.textLineFragments.enumerated() {
                let range = NSRange(
                    location: start + line.characterRange.location, length: line.characterRange.length)
                let top = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
                let visible =
                    range.location < string.length
                    ? string.substring(with: range).trimmingCharacters(in: .newlines) : ""
                lines.append(
                    LaidOutLine(
                        range: range, baseline: top + line.glyphOrigin.y,
                        bottom: top + line.typographicBounds.height,
                        hasText: !visible.isEmpty, isWrapped: index > 0))
            }
            return true
        }
        return lines
    }

    @Test func whatAParagraphHolds() {
        let string = "Text.\n\nMore\n" as NSString
        #expect(ParagraphContent(ofParagraphAt: 2, in: string) == .text)
        #expect(ParagraphContent(ofParagraphAt: 5, in: string) == .text, "its break")
        #expect(ParagraphContent(ofParagraphAt: 6, in: string) == .empty)
        #expect(ParagraphContent(ofParagraphAt: 11, in: string) == .text)
        #expect(
            ParagraphContent(ofParagraphAt: string.length, in: string) == .emptyEnd, "after the final break")
        #expect(ParagraphContent(ofParagraphAt: 0, in: "") == .emptyEnd)
        #expect(ParagraphContent(ofParagraphAt: 3, in: "Text" as NSString) == .text)
        #expect(ParagraphContent(ofParagraphAt: 4, in: "Text" as NSString) == .text, "at the end of text")
    }
}
