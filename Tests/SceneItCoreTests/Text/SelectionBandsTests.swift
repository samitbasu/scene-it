import AppKit
import Testing

@testable import SceneItCore

struct SelectionBandsTests {
    /// The cursor's height: TextKit's single-spaced line, the font's rounded ascent and descent and
    /// its leading.
    @Test func aBandIsASingleSpacedLineTall() {
        let font = ParagraphRole.body.font([])
        #expect(ParagraphRole.textLineHeight == ceil(font.ascender) + ceil(-font.descender) + font.leading)
    }

    @Test func aSegmentReachingUpOverTheSpacingKeepsOnlyItsLine() {
        let line = ParagraphRole.textLineHeight
        let segment = CGRect(x: 10, y: 100, width: 50, height: line + ParagraphRole.doubleSpacingGap)
        #expect(
            SelectionBands.band(in: segment) == CGRect(x: 10, y: segment.maxY - line, width: 50, height: line)
        )
        let first = CGRect(x: 10, y: 100, width: 50, height: line)
        #expect(SelectionBands.band(in: first) == first)
    }

    @Test func aSelectedBreakIsAtLeastASpaceWide() {
        let band = SelectionBands.band(
            in: CGRect(x: 36, y: 0, width: 0, height: ParagraphRole.textLineHeight))
        #expect(band.width == SelectionBands.breakWidth)
        #expect(SelectionBands.breakWidth > 2 && SelectionBands.breakWidth < 4, "a space of 12 pt Times")
    }
}
