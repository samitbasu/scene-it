import AppKit
import SceneItCore
import Testing

@testable import SceneIt

/// Clicking commented text selects its comment (PLAN §8.1), through the page's own `mouseDown`
/// with events made in this process; and the underlines follow a recolor.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CommentClickTests {
    static let older = Comment(
        id: CommentID(rawValue: "01JC4K0000000000000000OLD1"), color: .red, text: "Older",
        created: Timestamp(Date(timeIntervalSince1970: 1_700_000_000), in: .gmt))
    static let newer = Comment(
        id: CommentID(rawValue: "01JC4K0000000000000000NEW1"), color: .blue, text: "Newer",
        created: Timestamp(Date(timeIntervalSince1970: 1_700_000_100), in: .gmt))

    /// "The letter waited.": "letter" under both comments, "waited" under the older alone.
    static func commentedScene() -> BookScene {
        var ids = IDGenerator.system
        return BookScene(
            id: ids.sceneID(), modified: Timestamp(.now, in: .current), title: "Commented",
            body: [
                [
                    Run("The "), Run("letter", comments: [older.id, newer.id]),
                    Run(" waited", comments: [older.id]), Run("."),
                ],
                [Run("Dawn.")],
            ],
            comments: [older, newer])
    }

    @Test func clickingCommentedTextSelectsTheNewestThenCycles() async throws {
        try await withPage([Self.commentedScene()]) { harness in
            let selection = try #require(harness.page.editor?.comments)
            let scene = try #require(harness.book.openScene)
            var picks: [CommentID?] = []
            for _ in 0..<3 {
                try Self.click(harness, onCharacter: 6)
                picks.append(selection.comment(in: scene))
            }
            #expect(picks == [Self.newer.id, Self.older.id, Self.newer.id])
            try Self.click(harness, onCharacter: 1)
            #expect(selection.comment(in: scene) == Self.newer.id, "uncommented text changes nothing")
            try Self.click(harness, onCharacter: 13)
            #expect(selection.comment(in: scene) == Self.older.id, "the only comment on \"waited\"")
            #expect(harness.page.selectedRange().length == 0, "the click placed the caret as usual")
        }
    }

    /// The underlines are in the spacing below the line; clicking one is clicking its text.
    @Test func clickingAnUnderlineSelectsItsComment() async throws {
        try await withPage([Self.commentedScene()]) { harness in
            let selection = try #require(harness.page.editor?.comments)
            let scene = try #require(harness.book.openScene)
            let letter = try Self.frame(of: 6, in: harness.page)
            let underBlue = CGPoint(x: letter.midX, y: Self.baseline(of: letter) + 6.5)
            try Self.click(harness, at: underBlue)
            #expect(selection.comment(in: scene) == Self.newer.id)
        }
    }

    /// Recoloring a comment redraws the underlines already on the page in its new color.
    @Test func aRecolorRedrawsTheUnderlines() async throws {
        try await withPage([Self.commentedScene()]) { harness in
            let page = harness.page
            let waited = try Self.frame(of: 13, in: page)
            #expect(try Self.colors(below: waited, in: page).contains(.red))
            let pink = Comment(id: Self.older.id, color: .pink, text: "Older", created: Self.older.created)
            page.commentPalette = CommentPalette([pink, Self.newer])
            await eventually { (try? Self.colors(below: waited, in: page).contains(.pink)) == true }
            #expect(try !Self.colors(below: waited, in: page).contains(.red))
        }
    }

    // MARK: Support

    /// The character at `index`'s segment, in the page's coordinates.
    static func frame(of index: Int, in page: SceneTextView) throws -> CGRect {
        let layout = try #require(page.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let start = try #require(content.location(layout.documentRange.location, offsetBy: index))
        let end = try #require(content.location(start, offsetBy: 1))
        var frame: CGRect?
        layout.enumerateTextSegments(
            in: try #require(NSTextRange(location: start, end: end)), type: .standard, options: []
        ) { _, segment, _, _ in
            frame = segment
            return false
        }
        let origin = page.textContainerOrigin
        return try #require(frame).offsetBy(dx: origin.x, dy: origin.y)
    }

    /// A segment's baseline: its letters' slot is its bottom line height (ADR 0034).
    static func baseline(of segment: CGRect) -> CGFloat {
        segment.maxY - (ParagraphRole.textLineHeight - 11)
    }

    static func click(_ harness: PageHarness, onCharacter index: Int) throws {
        let frame = try frame(of: index, in: harness.page)
        try click(harness, at: CGPoint(x: frame.midX, y: baseline(of: frame) - 4))
    }

    /// A single click at `point` in the page: a mouse-up queued for the page's tracking loop, then
    /// the mouse-down handed to the page.
    static func click(_ harness: PageHarness, at point: CGPoint) throws {
        let location = harness.page.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: harness.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        harness.window.postEvent(try event(.leftMouseUp), atStart: false)
        harness.page.mouseDown(with: try event(.leftMouseDown))
    }

    /// The palette colors drawn in the room below `segment`, in the column at its middle, at 2×.
    static func colors(below segment: CGRect, in page: SceneTextView) throws -> Set<PaletteColor> {
        let baseline = baseline(of: segment)
        let rect = CGRect(x: segment.minX, y: baseline, width: segment.width, height: 17).integral
        let rep = WindowRenders.blankBitmap(width: Int(rect.width) * 2, height: Int(rect.height) * 2)
        rep.size = rect.size
        page.cacheDisplay(in: rect, to: rep)
        var found: Set<PaletteColor> = []
        for row in 0..<rep.pixelsHigh {
            guard let pixel = rep.colorAt(x: rep.pixelsWide / 2, y: row)?.usingColorSpace(.sRGB) else {
                continue
            }
            for color in PaletteColor.allCases where color != .black {
                let target = try #require(color.nsColor.usingColorSpace(.sRGB))
                let distance =
                    abs(pixel.redComponent - target.redComponent)
                    + abs(pixel.greenComponent - target.greenComponent)
                    + abs(pixel.blueComponent - target.blueComponent)
                if distance < 0.15 { found.insert(color) }
            }
        }
        return found
    }
}
