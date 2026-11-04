import AppKit
import SceneItCore
import Testing

@testable import SceneIt

/// Clicking commented text selects its comment (PLAN §8.1), through the page's own `mouseDown`
/// with events made in this process; and the underlines and the selection follow the model.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CommentClickTests {
    static let older = Comment(
        id: CommentID(rawValue: "01JC4K0000000000000000OLD1"), color: .red, text: "Older",
        created: Timestamp(Date(timeIntervalSince1970: 1_700_000_000), in: .gmt))
    static let newer = Comment(
        id: CommentID(rawValue: "01JC4K0000000000000000NEW1"), color: .blue, text: "Newer",
        created: Timestamp(Date(timeIntervalSince1970: 1_700_000_100), in: .gmt))

    static let long = Array(repeating: "harbor lights", count: 30).joined(separator: " ")

    /// "The letter waited.": "letter" under both comments, "waited" under the older alone; then
    /// a long paragraph, with letters below the underlines.
    static func commentedScene() -> BookScene {
        var ids = IDGenerator.system
        return BookScene(
            id: ids.sceneID(), modified: Timestamp(.now, in: .current), title: "Commented",
            body: [
                [
                    Run("The "), Run("letter", comments: [older.id, newer.id]),
                    Run(" waited", comments: [older.id]), Run("."),
                ],
                [Run(long)],
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
            #expect(harness.page.selectedRange().length == 0, "the click placed the caret")
            #expect((6...7).contains(harness.page.selectedRange().location), "where it clicked")
            try Self.click(harness, onCharacter: 1)
            #expect(selection.comment(in: scene) == Self.newer.id, "uncommented text changes nothing")
            try Self.click(harness, onCharacter: 13)
            #expect(selection.comment(in: scene) == Self.older.id, "the only comment on \"waited\"")
        }
    }

    /// The underlines are in the spacing below the line, above the next paragraph's letters;
    /// clicking one is clicking its text.
    @Test func clickingAnUnderlineSelectsItsComment() async throws {
        try await withPage([Self.commentedScene()]) { harness in
            let selection = try #require(harness.page.editor?.comments)
            let scene = try #require(harness.book.openScene)
            let letter = try Self.frame(of: 6, in: harness.page)
            let below = try Self.frame(of: 19 + 6, in: harness.page)
            try #require(below.minX <= letter.midX + 40, "precondition: the next paragraph has letters there")
            let underBlue = CGPoint(x: letter.midX, y: Self.baseline(of: letter) + 6.5)
            try Self.click(harness, at: underBlue)
            #expect(selection.comment(in: scene) == Self.newer.id)
        }
    }

    /// Only plain clicks: not a Shift- or Command-click, nor a press that drags out a selection
    /// (the owner's call, #24).
    @Test func onlyAPlainClickSelectsAComment() async throws {
        try await withPage([Self.commentedScene()]) { harness in
            let selection = try #require(harness.page.editor?.comments)
            let scene = try #require(harness.book.openScene)
            let letter = try Self.frame(of: 6, in: harness.page)
            let point = CGPoint(x: letter.midX, y: Self.baseline(of: letter) - 4)
            for modifiers: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
                try Self.click(harness, at: point, modifiers: modifiers)
                #expect(selection.comment(in: scene) == nil, "\(modifiers)")
            }
            harness.page.setSelectedRange(NSRange(location: 0, length: 0))
            try Self.click(harness, at: point, draggingTo: try Self.frame(of: 15, in: harness.page).center)
            #expect(
                harness.page.selectedRange().length > 0, "precondition: the press dragged out a selection")
            #expect(selection.comment(in: scene) == nil)
        }
    }

    /// A double click's first press is a plain click and selects once; its second press, which
    /// selects the word, changes nothing (the owner's call, #24).
    @Test func aDoubleClickSelectsOnce() async throws {
        try await withPage([Self.commentedScene()]) { harness in
            let selection = try #require(harness.page.editor?.comments)
            let scene = try #require(harness.book.openScene)
            let letter = try Self.frame(of: 6, in: harness.page)
            let point = CGPoint(x: letter.midX, y: Self.baseline(of: letter) - 4)
            try Self.click(harness, at: point)
            try Self.click(harness, at: point, clickCount: 2)
            #expect(
                selection.comment(in: scene) == Self.newer.id, "the first press selected the newest, once")
        }
    }

    /// Undoing a paste takes its comment away, and the selection with it; redoing it brings the
    /// comment back to the page, its underline drawn.
    @Test func theSelectionAndTheUnderlinesFollowTheModel() async throws {
        let source = scene("One", letterScene, .withTooEarly)
        let destination = scene("Two", [[Run("Elsewhere.")]])
        try await withPage([source, destination]) { harness in
            let selection = try #require(harness.page.editor?.comments)
            try await PageHarness.withPasteboard { pasteboard in
                harness.window.makeFirstResponder(harness.page)
                harness.page.setSelectedRange(NSRange(location: 4, length: 6))
                #expect(
                    harness.page.writeSelection(to: pasteboard, types: harness.page.writablePasteboardTypes))
                harness.book.select(destination.id)
                await eventually { harness.storage.string == "Elsewhere." }
                harness.focusPage(at: 0)
                #expect(harness.page.readSelection(from: pasteboard))
                let copy = try #require(harness.book.book.scene(destination.id)?.comments.first?.id)
                await eventually { harness.page.commentPalette.covers(copy) }
                try Self.click(harness, onCharacter: 2)
                #expect(selection.comment(in: destination.id) == copy)

                let undo = try #require(harness.page.undoManager)
                undo.undo()
                await eventually { selection.selected == nil }
                #expect(!harness.page.commentPalette.covers(copy))
                undo.redo()
                await eventually { harness.page.commentPalette.covers(copy) }
                let letter = try Self.frame(of: 2, in: harness.page)
                await eventually {
                    (try? Self.colors(below: letter, in: harness.page).contains(.purple)) == true
                }
            }
        }
    }

    /// Recoloring a comment redraws the underlines already on the page in its new color, and a
    /// scene scrolled far down stays where it was.
    @Test func aRecolorRedrawsTheUnderlinesAndKeepsTheScroll() async throws {
        var longScene = Self.commentedScene()
        longScene.body = Array(repeating: Paragraph([Run(Self.long)]), count: 120) + longScene.body
        try await withPage([longScene]) { harness in
            let page = harness.page
            page.scrollToEndOfDocument(nil)
            await eventually { page.visibleRect.maxY >= page.bounds.maxY - 1 }
            let start = 120 * (Self.long.count + 1)
            let waited = try Self.frame(of: start + 13, in: page)
            await eventually { (try? Self.colors(below: waited, in: page).contains(.red)) == true }
            let scrolled = page.visibleRect.origin
            let pink = Comment(id: Self.older.id, color: .pink, text: "Older", created: Self.older.created)
            page.commentPalette = CommentPalette([pink, Self.newer])
            await eventually { (try? Self.colors(below: waited, in: page).contains(.pink)) == true }
            #expect(try !Self.colors(below: waited, in: page).contains(.red))
            #expect(abs(page.visibleRect.origin.y - scrolled.y) < 0.5, "the scroll didn't move")
        }
    }

    // MARK: The notes have no comments (the owner's ruling, ADR 0032; pasting, in NotesTests)

    /// Notes from a file that anchors a comment in them (the format allows it, ADR 0032) show no
    /// underline, and a click there selects nothing.
    /// A comment the file anchored in the notes survives a cut and paste within them, and its
    /// undo and redo, through the notes' own editor (ADR 0035): nothing is silently detached.
    @Test func aCommentTheNotesOpenedWithSurvivesACutAndPasteThere() async throws {
        var commented = scene("One", letterScene, .withTooEarly)
        commented.notes = [[Run("The "), Run("letter", comments: [noted]), Run(" again.")]]
        try await withPage([commented]) { harness in
            let notes = try await harness.showNotes()
            await eventually { notes.string == "The letter again." }
            @MainActor func carried() -> Bool {
                harness.book.book.scene(commented.id).map { Paragraph.commentIDs(in: $0.notes) == [noted] }
                    ?? false
            }
            try await PageHarness.withPasteboard { pasteboard in
                harness.focusNotes(notes, at: 4)
                notes.setSelectedRange(NSRange(location: 4, length: 6))
                #expect(notes.writeSelection(to: pasteboard, types: notes.writablePasteboardTypes))
                notes.delete(nil)
                #expect(!carried(), "precondition: cut")
                notes.setSelectedRange(NSRange(location: 0, length: 0))
                #expect(notes.readSelection(from: pasteboard))
                #expect(carried(), "pasted back with its comment")
                let undo = try #require(notes.undoManager)
                await undoInAnEvent(undo)
                await undoInAnEvent(undo)
                #expect(carried(), "the cut undone")
                await undoInAnEvent(undo, .redo)
                await undoInAnEvent(undo, .redo)
                #expect(carried(), "and redone")
                #expect(harness.book.book.scene(commented.id)?.comments == [tooEarly])
            }
        }
    }

    @Test func theNotesDrawNoUnderlinesAndClicksThereSelectNothing() async throws {
        var commented = scene("One", letterScene, .withTooEarly)
        commented.notes = [[Run("The "), Run("letter", comments: [noted]), Run(" again.")]]
        try await withPage([commented]) { harness in
            let notes = try await harness.showNotes()
            await eventually { notes.string == "The letter again." }
            #expect(notes.textLayoutManager?.delegate == nil, "TextKit's own fragments")
            let letter = try Self.frame(of: 6, in: notes)
            #expect(try Self.colors(below: letter, in: notes).isEmpty)
            try Self.click(harness, onCharacter: 6, in: notes)
            let selection = try #require(harness.page.editor?.comments)
            #expect(selection.selected == nil)
            #expect((6...7).contains(notes.selectedRange().location), "the click placed the caret")
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

    static func click(_ harness: PageHarness, onCharacter index: Int, in view: SceneTextView? = nil) throws {
        let view = view ?? harness.page
        let frame = try frame(of: index, in: view)
        try click(harness, at: CGPoint(x: frame.midX, y: baseline(of: frame) - 4), in: view)
    }

    /// A single press at `point` in `view` (the page), released there or at `end` after dragging
    /// to it: the drag and the release queued for the view's tracking loop, then the press handed
    /// to the view.
    static func click(
        _ harness: PageHarness, at point: CGPoint, in view: SceneTextView? = nil,
        modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1, draggingTo end: CGPoint? = nil
    ) throws {
        let view = view ?? harness.page
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: harness.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
        }
        if let end {
            harness.window.postEvent(try event(.leftMouseDragged, at: end), atStart: false)
        }
        harness.window.postEvent(try event(.leftMouseUp, at: end ?? point), atStart: false)
        view.mouseDown(with: try event(.leftMouseDown, at: point))
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

extension CGRect {
    fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}
