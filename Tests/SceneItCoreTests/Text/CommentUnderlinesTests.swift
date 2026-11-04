import AppKit
import Testing

@testable import SceneItCore

struct CommentUnderlinesTests {
    // `Comment` names Testing's type too, so these are written without it.
    static let older = Comment(id: CommentID(rawValue: "older"), color: .red, text: "", created: at(10))
    static let newer = Comment(id: CommentID(rawValue: "newer"), color: .blue, text: "", created: at(20))
    static let newest = Comment(id: CommentID(rawValue: "newest"), color: .green, text: "", created: at(30))
    static let palette = CommentPalette([newest, older, newer])

    static func at(_ second: Int64) -> Timestamp {
        Timestamp(secondsSince1970: second, offset: .zero)
    }

    /// "aaaa" under `older`, "bbbb" under both (and `third`), "cccc" under `newer`, "dddd" under
    /// neither.
    static func overlapping(_ third: CommentID? = nil) -> NSAttributedString {
        let both: Set = [older.id, newer.id]
        return RunCodec.attributedString(
            forBody: [
                [
                    Run("aaaa", comments: [older.id]),
                    Run("bbbb", comments: third.map { both.union([$0]) } ?? both),
                    Run("cccc", comments: [newer.id]), Run("dddd"),
                ]
            ])
    }

    @Test func eachCommentKeepsOneLevelAcrossTheParagraph() {
        let lines = Self.palette.underlines(of: Self.overlapping(), depth: 4)
        #expect(
            lines == [
                CommentUnderline(NSRange(location: 0, length: 8), level: 0, color: .red),
                CommentUnderline(NSRange(location: 4, length: 8), level: 1, color: .blue),
            ])
    }

    @Test func ofCommentsStartingTogetherTheOlderIsNearer() {
        let text = RunCodec.attributedString(forBody: [
            [Run("abc", comments: [Self.newer.id, Self.older.id])]
        ])
        let lines = Self.palette.underlines(of: text, depth: 4)
        #expect(lines.map(\.color) == [.red, .blue])
        #expect(lines.map(\.level) == [0, 1])
    }

    /// ADR 0032's fallback, where the stack is deeper than fits: one line in the newest color.
    @Test func aStackTooDeepIsOneLineInTheNewestColor() {
        let lines = Self.palette.underlines(of: Self.overlapping(Self.newest.id), depth: 2)
        #expect(
            lines == [
                CommentUnderline(NSRange(location: 0, length: 4), level: 0, color: .red),
                CommentUnderline(NSRange(location: 4, length: 4), level: 0, color: .green),
                CommentUnderline(NSRange(location: 8, length: 4), level: 1, color: .blue),
            ])
        #expect(Self.palette.underlines(of: Self.overlapping(Self.newest.id), depth: 3).count == 3)
    }

    @Test func aCommentTheSceneDoesntHaveIsNotDrawn() {
        let text = RunCodec.attributedString(forBody: [[Run("abc", comments: [CommentID(rawValue: "gone")])]])
        #expect(Self.palette.underlines(of: text, depth: 4).isEmpty)
    }

    /// In the double spacing below a line (ADR 0034), down to a point above the next line's slot.
    @Test func howManyStackBelowABodyLine() throws {
        let fragment = try #require(Self.layOut(Self.overlapping()).first)
        let line = try #require(fragment.textLineFragments.first)
        let style = ParagraphRole.body.paragraphStyle
        #expect(line.typographicBounds.height - line.glyphOrigin.y + style.lineSpacing == 17.509765625)
        #expect(UnderlineStyle.thin.depth(below: line, spacedBy: style) == 5)
        #expect(UnderlineStyle.medium.depth(below: line, spacedBy: style) == 4)
        #expect(UnderlineStyle.thick.depth(below: line, spacedBy: style) == 3)
        #expect(UnderlineStyle.mediumTight.depth(below: line, spacedBy: style) == 5)
        #expect(UnderlineStyle.mediumHigh.depth(below: line, spacedBy: style) == 4)
    }

    @Test func aLineAcrossAWrapStopsAtItsLastLetter() throws {
        let words = Array(repeating: "harbor lights", count: 30).joined(separator: " ")
        let text = RunCodec.attributedString(forBody: [[Run(words, comments: [Self.older.id])]])
        let fragment = try #require(Self.layOut(text).first)
        let lines = fragment.textLineFragments
        try #require(lines.count >= 2, "precondition: the comment wraps")
        let rects = fragment.underlineRects()
        #expect(rects.count == lines.count)
        let first = try #require(rects.first?.rect)
        let firstLine = lines[0]
        let lastLetter = firstLine.characterRange.upperBound - 2
        #expect(
            first.maxX == firstLine.typographicBounds.minX
                + firstLine.locationForCharacter(at: lastLetter + 1).x)
        #expect(first.minY == firstLine.typographicBounds.minY + firstLine.glyphOrigin.y + 3)
        #expect(first.height == 1.5)
    }

    @Test func theSurfaceReachesTheDeepestLineBelowTheLastLine() throws {
        let fragment = try #require(Self.layOut(Self.overlapping()).first)
        let last = try #require(fragment.textLineFragments.last)
        let deepest = try #require(fragment.underlineRects().map(\.rect.maxY).max())
        #expect(deepest > last.typographicBounds.maxY, "precondition: a line below the text's slot")
        #expect(fragment.renderingSurfaceBounds.maxY >= deepest)
    }

    static func layOut(_ text: NSAttributedString) -> [CommentUnderlineFragment] {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let underliner = CommentUnderliner()
        layout.delegate = underliner
        underliner.show(palette, in: .standard, laidOutBy: layout)
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 468, height: 10_000))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        content.attributedString = text
        var fragments: [CommentUnderlineFragment] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
            if let fragment = $0 as? CommentUnderlineFragment { fragments.append(fragment) }
            return true
        }
        return withExtendedLifetime(underliner) { fragments }
    }
}
