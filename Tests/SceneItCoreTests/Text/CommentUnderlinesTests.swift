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

    @Test func theCommentsAtACharacterAreNewestFirst() {
        let text = Self.overlapping()
        #expect(Self.palette.newestFirst(at: 5, in: text) == [Self.newer.id, Self.older.id])
        #expect(Self.palette.newestFirst(at: 0, in: text) == [Self.older.id])
        #expect(Self.palette.newestFirst(at: 13, in: text).isEmpty)
        #expect(Self.palette.newestFirst(at: text.length, in: text).isEmpty)
    }

    /// In the double spacing below a line (ADR 0034), down to a point above the next line's slot.
    @Test func fiveStackBelowABodyLine() throws {
        let layout = Layout(Self.overlapping())
        let line = try #require(layout.fragments.first?.textLineFragments.first)
        let style = ParagraphRole.body.paragraphStyle
        #expect(line.typographicBounds.height - line.glyphOrigin.y + style.lineSpacing == 17.509765625)
        #expect(UnderlineStyle.depth(below: line, spacedBy: style, at: nil) == 5)
    }

    /// The notes are single-spaced: no line fits below their letters (what they show instead is
    /// `TightRoom`'s).
    @Test func noneFitsBelowANotesLine() throws {
        let layout = Layout(RunCodec.attributedString(forNotes: [[Run("Notes.")]]))
        let line = try #require(layout.fragments.first?.textLineFragments.first)
        #expect(UnderlineStyle.depth(below: line, spacedBy: ParagraphRole.notes.paragraphStyle, at: nil) == 0)
    }

    /// Whole pixels from the baseline's, the same number between every two levels.
    @Test func linesMeetThePixelsEvenly() {
        let (single, double) = (DeviceStep(pixelsPerPoint: 1), DeviceStep(pixelsPerPoint: 2))
        #expect((0..<5).map { UnderlineStyle.pixels(of: $0, at: single).top } == [3, 6, 9, 12, 15])
        #expect(UnderlineStyle.pixels(of: 0, at: single).height == 1)
        #expect((0..<5).map { UnderlineStyle.pixels(of: $0, at: double).top } == [6, 11, 16, 21, 26])
        #expect(UnderlineStyle.pixels(of: 0, at: double).height == 2)
    }

    /// The lines as they're drawn: red then blue, one pixel at 1×, two at 2×, each a whole
    /// number of pixels below the baseline's row.
    @Test(arguments: [1, 2]) func theLinesArePixelsBelowTheBaseline(scale: Int) throws {
        let layout = Layout(Self.overlapping())
        let fragment = try #require(layout.fragments.first)
        let line = try #require(fragment.textLineFragments.first)
        try #require(
            line.glyphOrigin.y == 11 && line.typographicBounds.minY == 0, "precondition: baseline at 11 pt")
        let column = line.typographicBounds.minX + line.locationForCharacter(at: 6).x
        let rows = try Self.coloredRows(of: fragment, at: column, step: CGFloat(scale))
        let step = DeviceStep(pixelsPerPoint: CGFloat(scale))
        let red = UnderlineStyle.pixels(of: 0, at: step)
        let blue = UnderlineStyle.pixels(of: 1, at: step)
        let baseline = 11 * scale
        #expect(rows[.red] == Array(baseline + red.top..<baseline + red.top + red.height))
        #expect(rows[.blue] == Array(baseline + blue.top..<baseline + blue.top + blue.height))
        #expect(rows[.red]?.count == scale && rows[.blue]?.count == scale)
    }

    /// At every zoom on either display (2× at 75% and 125%, 1× at 50% and 150%, among others),
    /// the deepest line drawn stays above the next line's slot and inside the surface TextKit
    /// gives the paragraph: past what fits, the stretch has the fallback.
    @Test(arguments: [0.5, 0.67, 0.75, 1.25, 1.5, 1.75, 2.5, 3, 4, 6])
    func aStackFitsAtEveryZoom(pixelsPerPoint: Double) throws {
        let step = CGFloat(pixelsPerPoint)
        let layout = Layout(
            RunCodec.attributedString(forBody: [Self.sixDeep.paragraph]), Self.sixDeep.palette)
        let fragment = try #require(layout.fragments.first)
        let line = try #require(fragment.textLineFragments.first)
        try #require(
            line.glyphOrigin.y == 11 && line.typographicBounds.minY == 0, "precondition: baseline at 11 pt")
        let depth = UnderlineStyle.depth(
            below: line, spacedBy: ParagraphRole.body.paragraphStyle, at: DeviceStep(pixelsPerPoint: step))
        #expect((1...5).contains(depth))
        let deepest = try #require(
            fragment.underlineRects(at: DeviceStep(pixelsPerPoint: step)).max { $0.level < $1.level })
        #expect(deepest.level == depth - 1, "the stack is as deep as fits, no deeper")
        let column = deepest.rect.midX
        let lowest = try #require(
            Self.coloredRows(of: fragment, at: column, step: step).values.flatMap(\.self).max())
        let nextSlot = (line.typographicBounds.maxY + ParagraphRole.body.paragraphStyle.lineSpacing) * step
        #expect(CGFloat(lowest + 1) <= nextSlot, "above the next line's slot")
        #expect(CGFloat(lowest + 1) <= fragment.renderingSurfaceBounds.maxY * step, "inside the surface")
    }

    /// ADR 0032's fallback past five: six comments, each a word later, all ending together.
    @Test func pastFiveTheStackIsOneLineInTheNewestColor() throws {
        let layout = Layout(
            RunCodec.attributedString(forBody: [Self.sixDeep.paragraph]), Self.sixDeep.palette)
        let lines = try #require(layout.fragments.first).underlineRects()
        #expect(lines.map(\.level).max() == 4)
        let six = try #require(lines.last)
        #expect(six.color == .gray && six.level == 0, "the newest of six, nearest the text")
        #expect(lines.dropLast().allSatisfy { $0.rect.maxX <= six.rect.minX + 0.01 }, "alone under six")
        #expect(lines.filter { $0.color == .pink }.count == 1, "five still stacks")
    }

    /// Six comments, each starting a word later and all ending together, the newest gray.
    static let sixDeep: (paragraph: Paragraph, palette: CommentPalette) = {
        let colors: [PaletteColor] = [.red, .blue, .green, .purple, .pink, .gray]
        let comments = colors.enumerated().map { index, color in
            Comment(
                id: CommentID(rawValue: "deep\(index)"), color: color, text: "",
                created: CommentUnderlinesTests.at(Int64(index)))
        }
        let words = ["one ", "two ", "three ", "four ", "five ", "six"]
        let runs = words.indices.map { index in
            Run(words[index], comments: Set(comments.prefix(index + 1).map(\.id)))
        }
        return (Paragraph(runs), CommentPalette(comments))
    }()

    @Test func aLineAcrossAWrapStopsAtItsLastLetter() throws {
        let words = Array(repeating: "harbor lights", count: 30).joined(separator: " ")
        let layout = Layout(RunCodec.attributedString(forBody: [[Run(words, comments: [Self.older.id])]]))
        let fragment = try #require(layout.fragments.first)
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
        #expect(first.height == 1)
    }

    /// TextKit keeps a paragraph's fragment when its layout is invalidated, so a fragment made
    /// before a recolor must draw in the new color.
    @Test func aRecolorReachesAFragmentAlreadyLaidOut() throws {
        let layout = Layout(Self.overlapping())
        let before = try #require(layout.fragments.first)
        #expect(before.underlineRects().map(\.color) == [.red, .blue])
        let recolored = Comment(id: Self.older.id, color: .pink, text: "", created: Self.older.created)
        layout.underliner.show(CommentPalette([recolored, Self.newer]), laidOutBy: layout.layout)
        #expect(layout.fragments.first === before, "precondition: TextKit kept the fragment")
        #expect(before.underlineRects().map(\.color) == [.pink, .blue])
    }

    @Test func theSurfaceReachesTheDeepestLineBelowTheLastLine() throws {
        let fragment = try #require(Layout(Self.overlapping()).fragments.first)
        let last = try #require(fragment.textLineFragments.last)
        let deepest = try #require(fragment.underlineRects().map(\.rect.maxY).max())
        #expect(deepest > last.typographicBounds.maxY, "precondition: a line below the text's slot")
        #expect(fragment.renderingSurfaceBounds.maxY >= deepest)
    }

    @Test func anUncommentedParagraphKeepsTextKitsSurface() throws {
        let layout = Layout(RunCodec.attributedString(forBody: [[Run("Nothing commented here.")]]))
        let fragment = try #require(layout.fragments.first)
        let line = try #require(fragment.textLineFragments.last)
        #expect(fragment.renderingSurfaceBounds.maxY < line.typographicBounds.maxY + 4)
    }

    @Test func aPaletteChangeNamesTheCommentsDrawnDifferently() {
        let recolored = Comment(id: Self.older.id, color: .pink, text: "", created: Self.older.created)
        #expect(
            Self.palette.changes(to: CommentPalette([recolored, Self.newer, Self.newest])) == [Self.older.id])
        #expect(Self.palette.changes(to: CommentPalette([Self.older, Self.newer])) == [Self.newest.id])
        #expect(Self.palette.changes(to: Self.palette).isEmpty)
    }

    // MARK: Hit-testing

    @Test func aPointOnALetterIsThatLetter() throws {
        let layout = Layout(Self.overlapping())
        let point = CGPoint(x: Self.x(of: 5, in: layout) + 1, y: 6)
        #expect(CommentUnderlineFragment.character(at: point, in: layout.layout) == 5)
    }

    /// The room below a paragraph's last line, where its underlines are, is inside the next
    /// paragraph's fragment; a click there is still on the letters above.
    @Test func aPointOnTheUnderlinesBelowAParagraphIsTheLetterAbove() throws {
        let layout = Layout(RunCodec.attributedString(forBody: [Self.overlappingParagraph, [Run("Next.")]]))
        let fragments = layout.fragments
        try #require(fragments.count == 2)
        let line = try #require(fragments[0].textLineFragments.last)
        let blue = line.glyphOrigin.y + UnderlineStyle.top(of: 1) + 0.5
        let point = CGPoint(x: Self.x(of: 9, in: layout) + 1, y: line.typographicBounds.minY + blue)
        try #require(
            fragments[1].layoutFragmentFrame.minY <= point.y, "precondition: in the next paragraph's band"
        )
        #expect(CommentUnderlineFragment.character(at: point, in: layout.layout) == 9)
    }

    /// The next paragraph's first line has letters at the same x: the click is still on the
    /// underlined letter above.
    @Test func aPointOnTheUnderlinesAboveALongParagraphIsTheLetterAbove() throws {
        let long = Array(repeating: "harbor lights", count: 30).joined(separator: " ")
        let layout = Layout(RunCodec.attributedString(forBody: [Self.overlappingParagraph, [Run(long)]]))
        let fragments = layout.fragments
        try #require(fragments.count == 2)
        let line = try #require(fragments[0].textLineFragments.last)
        let next = try #require(fragments[1].textLineFragments.first)
        let x = Self.x(of: 9, in: layout) + 1
        try #require(
            x > fragments[1].layoutFragmentFrame.minX + next.typographicBounds.minX
                && x < fragments[1].layoutFragmentFrame.minX + next.typographicBounds.maxX,
            "precondition: the next line has letters at this x")
        for depth in 0..<5 {
            let y = line.typographicBounds.minY + line.glyphOrigin.y + UnderlineStyle.top(of: depth) + 0.5
            #expect(CommentUnderlineFragment.character(at: CGPoint(x: x, y: y), in: layout.layout) == 9)
        }
        let onTheNextLine = CGPoint(
            x: x,
            y: fragments[1].layoutFragmentFrame.minY + next.typographicBounds.minY + next.glyphOrigin.y - 4)
        let index = try #require(CommentUnderlineFragment.character(at: onTheNextLine, in: layout.layout))
        #expect(index > Self.overlappingParagraph.text.count, "the next paragraph's letter")
    }

    @Test func aPointPastTheLinesEndIsNoLetter() throws {
        let layout = Layout(Self.overlapping())
        let fragment = try #require(layout.fragments.first)
        let line = try #require(fragment.textLineFragments.first)
        let point = CGPoint(x: fragment.layoutFragmentFrame.minX + line.typographicBounds.maxX + 20, y: 6)
        #expect(CommentUnderlineFragment.character(at: point, in: layout.layout) == nil)
    }

    // MARK: Support

    static let overlappingParagraph: Paragraph = [
        Run("aaaa", comments: [older.id]), Run("bbbb", comments: [older.id, newer.id]),
        Run("cccc", comments: [newer.id]), Run("dddd"),
    ]

    /// Where the character at `index` of the first paragraph starts, in the container.
    static func x(of index: Int, in layout: Layout) -> CGFloat {
        guard let fragment = layout.fragments.first, let line = fragment.textLineFragments.first else {
            return 0
        }
        return fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
            + line.locationForCharacter(at: index).x
    }

    /// Text laid out by TextKit 2 with underlines, as the editors lay it out.
    final class Layout {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let underliner = CommentUnderliner()

        init(_ text: NSAttributedString, _ palette: CommentPalette = CommentUnderlinesTests.palette) {
            layout.delegate = underliner
            underliner.show(palette, laidOutBy: layout)
            content.addTextLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(width: 468, height: 10_000))
            container.lineFragmentPadding = 0
            layout.textContainer = container
            content.attributedString = text
        }

        var fragments: [CommentUnderlineFragment] {
            var fragments: [CommentUnderlineFragment] = []
            layout.enumerateTextLayoutFragments(
                from: layout.documentRange.location, options: [.ensuresLayout]
            ) {
                if let fragment = $0 as? CommentUnderlineFragment { fragments.append(fragment) }
                return true
            }
            return fragments
        }
    }

    /// The rows, counted down from the top in pixels, where `fragment` drawn at `step` pixels a
    /// point shows a palette color, in the column at `x` points.
    static func coloredRows(of fragment: CommentUnderlineFragment, at x: CGFloat, step: CGFloat) throws
        -> [PaletteColor: [Int]]
    {
        let size = (width: Int((480 * step).rounded(.up)), height: Int((60 * step).rounded(.up)))
        let context = try #require(
            CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                bytesPerRow: size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.translateBy(x: 0, y: CGFloat(size.height))
        context.scaleBy(x: step, y: -step)
        fragment.draw(at: .zero, in: context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let column = Int(x * step)
        let targets = PaletteColor.allCases.filter { $0 != .black && $0 != .gray }.map { color in
            (color, color.nsColor.usingColorSpace(.sRGB)!)
        }
        var rows: [PaletteColor: [Int]] = [:]
        for row in 0..<size.height {
            let pixel = pixels + (row * size.width + column) * 4
            let channels = (0..<3).map { CGFloat(pixel[$0]) / 255 }
            for (color, target) in targets {
                let distance =
                    abs(channels[0] - target.redComponent) + abs(channels[1] - target.greenComponent)
                    + abs(channels[2] - target.blueComponent)
                if distance < 0.2 { rows[color, default: []].append(row) }
            }
        }
        return rows
    }
}
