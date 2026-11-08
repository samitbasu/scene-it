import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// Where a single-spaced line in the body's font puts its baseline, and how tall it is, as the
/// single-spaced notes lay it out.
@MainActor
private func singleSpacedLine() throws -> (height: CGFloat, baselineOffset: CGFloat) {
    let view = NSTextView(usingTextLayoutManager: true)
    view.textStorage?.setAttributedString(
        NSAttributedString(string: "Hg", attributes: ParagraphRole.notes.typingAttributes))
    let layout = try #require(view.textLayoutManager)
    var line: NSTextLineFragment?
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
        line = $0.textLineFragments.first
        return false
    }
    let first = try #require(line)
    return (first.typographicBounds.height, first.glyphOrigin.y)
}

/// The line holding the character at `location`, in the page's coordinates: its baseline, the
/// character's leading edge, and whether it's its paragraph's first line.
@MainActor
private func glyphLine(at location: Int, in page: ManuscriptTextView) throws
    -> (baseline: CGFloat, x: CGFloat, isFirstLine: Bool)
{
    let layout = try #require(page.textLayoutManager)
    let content = try #require(layout.textContentManager)
    let start = try #require(content.location(content.documentRange.location, offsetBy: location))
    layout.ensureLayout(for: NSTextRange(location: start))
    let fragment = try #require(layout.textLayoutFragment(for: start))
    let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
    let lines = fragment.textLineFragments
    let index = try #require(
        lines.firstIndex { NSLocationInRange(location - offset, $0.characterRange) },
        "a line holds \(location): \(lines.map(\.characterRange)) from \(offset) in \(fragment.rangeInElement)"
    )
    let line = lines[index]
    let origin = page.textContainerOrigin
    let x = line.locationForCharacter(at: location - offset).x
    return (
        origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y,
        origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + x,
        index == 0
    )
}

/// The text view's caret: the system's own, which the page no longer replaces (ADR 0034).
@MainActor
private func systemCaret(of page: PageHarness) throws -> NSTextInsertionIndicator {
    let carets = subviewTree(of: page.page).compactMap { $0 as? NSTextInsertionIndicator }
    try #require(carets.count == 1, "precondition: the page has one caret")
    return carets[0]
}

@MainActor
private func keyAndFocused(
    _ page: PageHarness, at location: Int, _ affinity: NSSelectionAffinity = .downstream
)
    async throws -> NSRect
{
    try #require(page.window.isKeyWindow, "precondition: a key window")
    page.focusPage(at: location)
    page.page.setSelectedRange(
        NSRange(location: location, length: 0), affinity: affinity, stillSelecting: false)
    let caret = try systemCaret(of: page)
    await eventually { !caret.isHidden && caret.frame.height > 0 }
    try #require(!caret.isHidden, "precondition: the caret shows")
    return caret.frame
}

/// The caret is text height around `baseline`: as tall as a single-spaced line, its top a
/// single-spaced ascent above the baseline.
@MainActor
private func expectTextHeight(
    _ caret: NSRect, onBaseline baseline: CGFloat, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let single = try singleSpacedLine()
    #expect(
        abs(caret.minY - (baseline - single.baselineOffset)) < 0.01, "top: \(caret) on \(baseline)",
        sourceLocation: sourceLocation)
    #expect(
        abs(caret.height - single.height) < 0.01, "a single-spaced line tall: \(caret)",
        sourceLocation: sourceLocation)
}

/// The caret at `location` is exactly where a letter typed there sits: at its leading edge, and
/// text height around its baseline.
@MainActor
private func expectCaretFitsTypedText(
    _ page: PageHarness, at location: Int, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let caret = try await keyAndFocused(page, at: location)
    page.page.insertText("x", replacementRange: NSRange(location: location, length: 0))
    let typed = try glyphLine(at: location, in: page.page)
    #expect(abs(caret.minX - typed.x) < 0.01, "at the letter's leading edge", sourceLocation: sourceLocation)
    try expectTextHeight(caret, onBaseline: typed.baseline, sourceLocation: sourceLocation)
}

private let long =
    "The ferry left before dawn, and nobody on the quay said a word about the letter that had come "
    + "for her in the night, though everyone had seen the boy run down the hill with it."

nonisolated private let zooms = [Zoom.standard, Zoom(clamping: 2)]

/// A wrapped paragraph, an empty one, a short one, and an empty last one.
private let body: [Paragraph] = [[Run(long)], [], [Run("Short.")], []]

@MainActor
private func settle(_ page: PageHarness, at zoom: Zoom) async throws {
    page.preferences.setZoom(zoom)
    let desk = try page.desk
    await eventually { abs(desk.magnification - Double(zoom)) < 0.0001 }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct CaretTests {
    @Test(arguments: zooms)
    func onATextLine(zoom: Zoom) async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            try await settle(page, at: zoom)
            try #require(try glyphLine(at: 5, in: page.page).isFirstLine, "precondition: the first line")
            try await expectCaretFitsTypedText(page, at: 5)
        }
    }

    @Test(arguments: zooms)
    func onAWrappedLine(zoom: Zoom) async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            try await settle(page, at: zoom)
            let location = (long as NSString).length - 10
            try #require(
                try !glyphLine(at: location, in: page.page).isFirstLine, "precondition: a wrapped line")
            try await expectCaretFitsTypedText(page, at: location)
        }
    }

    @Test func atTheEndOfAWrappedLine() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            let layout = try #require(page.page.textLayoutManager)
            let first = try #require(layout.textLayoutFragment(for: layout.documentRange.location))
            try #require(first.textLineFragments.count > 1, "precondition: the paragraph wraps")
            let lineEnd = first.textLineFragments[0].characterRange.upperBound
            let lastOnTheLine = try glyphLine(at: lineEnd - 1, in: page.page)
            let upstream = try await keyAndFocused(page, at: lineEnd, .upstream)
            #expect(upstream.minX > lastOnTheLine.x, "after the line's last letter")
            try expectTextHeight(upstream, onBaseline: lastOnTheLine.baseline)
        }
    }

    @Test func inAnEmptyParagraph() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            let location = (long as NSString).length + 1
            let string = page.storage.string as NSString
            try #require(
                string.character(at: location - 1) == 10 && string.character(at: location) == 10,
                "precondition: an empty paragraph")
            try await expectCaretFitsTypedText(page, at: location)
        }
    }

    @Test func atTheEndAfterAParagraphBreak() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            let location = page.storage.length
            try #require(
                page.storage.string.hasSuffix("\n"), "precondition: the body ends with an empty paragraph")
            try await expectCaretFitsTypedText(page, at: location)
        }
    }

    @Test func inAnEmptyScene() async throws {
        try await withPage([scene("One")], in: KeyWindow.self) { page in
            try #require(page.storage.length == 0, "precondition: an empty scene")
            try await expectCaretFitsTypedText(page, at: 0)
        }
    }

    @Test func inAParagraphEmptiedByDeletingItsText() async throws {
        try await withPage([scene("One", [[Run("Gone.")], [Run("Short.")]])], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: 5)
            page.page.setSelectedRange(NSRange(location: 0, length: 5))
            page.page.deleteBackward(nil)
            try #require(page.storage.string == "\nShort.", "precondition: the first paragraph is empty")
            #expect(page.pageMirrorsModel)
            try await expectCaretFitsTypedText(page, at: 0)
        }
    }

    @Test func afterReturnAtTheEnd() async throws {
        try await withPage([scene("One", [[Run("Short.")]])], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: 6)
            page.page.insertParagraphSeparator(nil)
            try #require(page.storage.string == "Short.\n", "precondition: an empty paragraph at the end")
            #expect(page.pageMirrorsModel)
            try await expectCaretFitsTypedText(page, at: 7)
        }
    }

    @Test func scrollingToTheCaretShowsIt() async throws {
        let paragraphs: [Paragraph] = Array(repeating: [Run(long)], count: 40)
        try await withPage([scene("Long", paragraphs)], in: KeyWindow.self) { page in
            let caret = try await keyAndFocused(page, at: page.storage.length)
            try #require(!page.page.visibleRect.contains(caret), "precondition: the caret starts out of view")
            page.page.scrollRangeToVisible(page.page.selectedRange())
            #expect(page.page.visibleRect.contains(try systemCaret(of: page).frame))
        }
    }
}

/// Each line of `view`'s text: its characters and its baseline, in the view's coordinates.
@MainActor
private func laidOutLines(of view: NSTextView) throws -> [(range: NSRange, baseline: CGFloat)] {
    let layout = try #require(view.textLayoutManager)
    let content = try #require(layout.textContentManager)
    let origin = view.textContainerOrigin
    var lines: [(range: NSRange, baseline: CGFloat)] = []
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
        fragment in
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        for line in fragment.textLineFragments where line.characterRange.length > 0 {
            let top = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
            lines.append(
                (
                    NSRange(
                        location: start + line.characterRange.location, length: line.characterRange.length),
                    top + line.glyphOrigin.y
                ))
        }
        return true
    }
    return lines
}

/// Selecting `range` in `view` draws one band per line it touches, each text height on its line's
/// baseline, as the cursor is.
@MainActor
private func expectBands(
    _ view: SceneTextView, selecting range: NSRange, lines expected: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    view.setSelectedRange(range)
    try expectBands(view, cover: [range], lines: expected, sourceLocation: sourceLocation)
}

/// The view's bands are one per line that `ranges` touch, each text height on its line's baseline.
@MainActor
private func expectBands(
    _ view: SceneTextView, cover ranges: [NSRange], lines expected: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let touched = try laidOutLines(of: view).filter { line in
        ranges.contains { NSIntersectionRange(line.range, $0).length > 0 }
    }
    try #require(
        touched.count == expected, "precondition: \(expected) lines selected", sourceLocation: sourceLocation)
    let bands = view.selectionBands
    #expect(bands.count == expected, "a band per line: \(bands)", sourceLocation: sourceLocation)
    for line in touched {
        let band = try #require(
            bands.first { abs($0.maxY - line.baseline) < 6 }, "a band on \(line.range)",
            sourceLocation: sourceLocation)
        try expectTextHeight(band, onBaseline: line.baseline, sourceLocation: sourceLocation)
    }
}

/// Four paragraphs: one line, two lines, an empty one, three lines.
private let selectionBody: [Paragraph] = [
    [Run("The ferry left at dawn.")],
    [Run(long)],
    [],
    [Run(long + " And then the boat came back for her, much later, when the tide had turned at last.")],
]

@Suite(.serialized, .timeLimit(.minutes(2)))
struct SelectionTests {
    @Test func theSystemHighlightIsOffAndTheCursorKeepsTheSystemColor() async throws {
        var withNotes = scene("One", selectionBody)
        withNotes.notes = [[Run("Check the tides.")]]
        try await withPage([withNotes], in: KeyWindow.self) { page in
            let notes = try await page.showNotes()
            for view in [page.page, notes] as [SceneTextView] {
                #expect(view.selectedTextAttributes[.backgroundColor] == nil, "no system highlight")
                #expect(
                    view.insertionPointColor == NSColor.textInsertionPointColor, "the system's cursor colour")
            }
        }
    }

    @Test func aBandPerLineWithinAndAcrossParagraphs() async throws {
        try await withPage([scene("One", selectionBody)], in: KeyWindow.self) { page in
            let view = page.page
            let string = page.storage.string as NSString
            let second = string.range(of: "The ferry left before").location
            let fourth = string.range(of: "The ferry left before", options: .backwards).location
            try expectBands(view, selecting: NSRange(location: 4, length: 10), lines: 1)
            try expectBands(view, selecting: NSRange(location: second + 10, length: 100), lines: 2)
            try expectBands(view, selecting: NSRange(location: fourth + 10, length: 200), lines: 3)
            try expectBands(view, selecting: NSRange(location: 10, length: second + 10 - 10), lines: 2)
            try expectBands(
                view, selecting: NSRange(location: fourth - 30, length: 40), lines: 3)
        }
    }

    @Test(arguments: zooms)
    func bandsScaleWithTheZoom(zoom: Zoom) async throws {
        try await withPage([scene("One", selectionBody)], in: KeyWindow.self) { page in
            try await settle(page, at: zoom)
            let string = page.storage.string as NSString
            let second = string.range(of: "The ferry left before").location
            try expectBands(page.page, selecting: NSRange(location: second + 10, length: 100), lines: 2)
            let band = try #require(page.page.selectionBands.first)
            let single = try singleSpacedLine()
            #expect(abs(page.page.convert(band, to: nil).height - single.height * Double(zoom)) < 0.01)
        }
    }

    @Test func theNotesHaveBandsToo() async throws {
        var withNotes = scene("One", selectionBody)
        withNotes.notes = [[Run("Check the tides before the crossing.")], [Run("Dawn in March?")]]
        try await withPage([withNotes], in: KeyWindow.self) { page in
            let notes = try await page.showNotes()
            let length = (notes.string as NSString).length
            try #require(notes.string.contains("\n"), "precondition: two paragraphs of notes")
            try expectBands(notes, selecting: NSRange(location: 2, length: length - 4), lines: 2)
        }
    }

    @Test func theAccentColourOnlyWithTheFocusInTheKeyWindow() async throws {
        try await withPage([scene("One", selectionBody)], in: KeyWindow.self) { page in
            page.focusPage(at: 0)
            page.page.setSelectedRange(NSRange(location: 0, length: 5))
            #expect(page.page.selectionColor == .selectedTextBackgroundColor)
            page.window.makeFirstResponder(page.title)
            #expect(
                page.page.selectionColor == .unemphasizedSelectedTextBackgroundColor,
                "the title has the focus")
            page.focusPage(at: 0)
            KeyWindow.isKey = false
            defer { KeyWindow.isKey = true }
            #expect(
                page.page.selectionColor == .unemphasizedSelectedTextBackgroundColor, "another window is key")
        }
    }

    /// What Find does with a match: selects it and points at it. The selection shows as its band.
    /// What Find does with a match, through the text view's own calls: it selects it and points
    /// at it. (Find itself reads the system's find pasteboard, which tests leave alone.)
    @Test func aSelectedMatchShowsAsItsBand() async throws {
        try await withPage([scene("One", selectionBody)], in: KeyWindow.self) { page in
            page.focusPage(at: 0)
            let match = (page.storage.string as NSString).range(of: "dawn")
            try #require(match.location != NSNotFound, "precondition: a match")
            page.page.setSelectedRange(match)
            page.page.showFindIndicator(for: match)
            try expectBands(page.page, selecting: match, lines: 1)
        }
    }

    @Test func aBandEndsAtTheLastSelectedLetter() async throws {
        try await withPage([scene("One", selectionBody)], in: KeyWindow.self) { page in
            let view = page.page
            let string = page.storage.string as NSString
            let firstLine = string.range(of: "The ferry left at dawn.")
            let end = string.range(of: "nobody").location
            try expectBands(view, selecting: NSRange(location: 4, length: end - 4), lines: 2)
            let bands = view.selectionBands.sorted { $0.minY < $1.minY }
            let period = try glyphLine(at: NSMaxRange(firstLine) - 1, in: view)
            #expect(bands[0].maxX > period.x, "past the period")
            #expect(bands[0].maxX < period.x + 10, "and no further than the break: \(bands[0])")
            let next = try glyphLine(at: end, in: view)
            #expect(abs(bands[1].maxX - next.x) < 0.01, "up to the next letter, unselected")
        }
    }

    @Test func discontiguousSelectionsEachGetTheirBands() async throws {
        try await withPage([scene("One", selectionBody)], in: KeyWindow.self) { page in
            let string = page.storage.string as NSString
            let ranges = [
                NSRange(location: 4, length: 5),
                NSRange(location: string.range(of: "nobody").location, length: 6),
            ]
            page.page.selectedRanges = ranges.map(NSValue.init(range:))
            try expectBands(page.page, cover: ranges, lines: 2)
        }
    }

    @Test func bandsAreClearedAsTheSelectionShrinksAndFollowTheWindowsWidth() async throws {
        try await withPage([scene("One", selectionBody)], in: KeyWindow.self) { page in
            let view = page.page
            page.focusPage(at: 0)
            let string = page.storage.string as NSString
            let second = string.range(of: "The ferry left before").location
            try expectBands(view, selecting: NSRange(location: second + 10, length: 100), lines: 2)
            let gone = try #require(view.selectionBands.max { $0.minY < $1.minY })
            let painted = try rendered(view, in: gone.insetBy(dx: 4, dy: 3), matching: view.selectionColor)
            try #require(painted > 0.3, "precondition: the band that goes was painted: \(painted)")
            try expectBands(view, selecting: NSRange(location: second + 10, length: 20), lines: 1)
            #expect(view.invalidatedBands.contains(gone), "the band that went is redrawn")
            #expect(
                view.invalidatedBands.count <= 3,
                "only the bands that changed (the one that went, and the first line's old and new): \(view.invalidatedBands)"
            )
            let color = try rendered(view, in: gone.insetBy(dx: 4, dy: 3), matching: view.selectionColor)
            #expect(color < 0.05, "the band no longer drawn is gone: \(color)")

            let range = view.selectedRange()
            var frame = page.window.frame
            frame.size.width += 300
            page.window.setFrame(frame, display: true)
            await eventually {
                (try? laidOutLines(of: view).first?.baseline) != nil
                    && view.selectionBands.first.map { $0.minX } != nil
            }
            try expectBands(view, cover: [range], lines: 1)
            let line = try glyphLine(at: range.location, in: view)
            #expect(abs((view.selectionBands.first?.minX ?? 0) - line.x) < 0.01, "moved with the text")
        }
    }

    @Test func bandsArePaintedOnThePageAndInTheNotesInTheFocusColour() async throws {
        var withNotes = scene("One", selectionBody)
        withNotes.notes = [[Run("Check the tides before the crossing.")], [Run("Dawn in March?")]]
        try await withPage([withNotes], in: KeyWindow.self) { page in
            page.focusPage(at: 0)
            let view = page.page
            try expectBands(view, selecting: NSRange(location: 4, length: 15), lines: 1)
            let band = try #require(view.selectionBands.first)
            let active = try rendered(view, in: band, matching: .selectedTextBackgroundColor)
            #expect(active > 0.3, "the band is painted in the accent colour: \(active)")
            page.window.makeFirstResponder(page.title)
            #expect(view.invalidatedBands == view.selectionBands, "losing the focus redraws the bands")
            let inactive = try rendered(view, in: band, matching: .unemphasizedSelectedTextBackgroundColor)
            #expect(inactive > 0.3, "and redrawn grey without the focus: \(inactive)")

            let notes = try await page.showNotes()
            page.window.makeFirstResponder(notes)
            try expectBands(notes, selecting: NSRange(location: 2, length: 10), lines: 1)
            let notesBand = try #require(notes.selectionBands.first)
            let inNotes = try rendered(notes, in: notesBand, matching: .selectedTextBackgroundColor)
            #expect(inNotes > 0.3, "the notes paint theirs too: \(inNotes)")
        }
    }

    @Test func selectingAllOfALongSceneDrawsOnlyWhatShows() async throws {
        let paragraphs: [Paragraph] = Array(repeating: [Run(long + " " + long)], count: 460)
        try await withPage([scene("Long", paragraphs)], in: KeyWindow.self) { page in
            let view = page.page
            try #require(try laidOutLines(of: view).count > 40 * 23, "precondition: over 40 pages of lines")
            page.focusPage(at: 0)
            view.selectAll(nil)
            let visibleLines = Int(view.visibleRect.height / 14) + 1
            try #require(!view.selectionBands.isEmpty, "precondition: bands where the text shows")
            #expect(
                view.selectionBands.count <= visibleLines * 2,
                "only the viewport's: \(view.selectionBands.count)")
            for step in 1...10 {
                let target = NSRect(x: 0, y: CGFloat(step) * 1500, width: 10, height: view.visibleRect.height)
                view.scrollToVisible(target)
                await eventually { view.selectionBands.contains { $0.intersects(view.visibleRect) } }
                #expect(
                    view.selectionBands.count <= visibleLines * 2,
                    "step \(step): only the viewport's bands, \(view.selectionBands.count)")
                #expect(
                    view.invalidatedBands.count <= visibleLines * 4,
                    "step \(step): only changed bands redrawn, \(view.invalidatedBands.count)")
            }
        }
    }
}

/// The share of `rect`'s pixels in `color` as the window composites `view` at 100% (its layers
/// rendered into a bitmap; nothing reads the screen), highlights and rendering attributes
/// included, which the view's own drawing leaves out.
@MainActor
private func composited(_ view: NSView, in rect: NSRect, matching color: NSColor) async throws -> Double {
    let root = try #require(view.window?.contentView?.superview)
    root.wantsLayer = true
    root.layoutSubtreeIfNeeded()
    root.display()
    let layer = try #require(root.layer)
    func render() throws -> NSBitmapImageRep {
        let rep = WindowRenders.blankBitmap(width: Int(rect.width), height: Int(rect.height))
        rep.size = rect.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        let inRoot = view.convert(rect, to: root)
        if root.isFlipped {
            context.translateBy(x: 0, y: rect.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.translateBy(x: -inRoot.minX, y: -inRoot.minY)
        layer.render(in: context)
        return rep
    }
    // The layers draw their contents on later turns of the run loop: render until the text shows.
    // Text drawn before the change shows too, and nothing signals that the layers have redrawn,
    // so the first render waits a turn.
    try await Task.sleep(for: .milliseconds(100))
    var rep = try render()
    await eventually {
        guard let next = try? render() else { return false }
        rep = next
        return ((try? share(of: .black, in: next, as: view)) ?? 0) > 0.01
    }
    return try share(of: color, in: rep, as: view)
}

/// The share of `rect`'s pixels in `color`, as `view` draws itself into a bitmap (nothing reads
/// the screen). The page's layers are tiled, which a layer render misses, so this is the view's own
/// drawing, where the bands are.
@MainActor
private func rendered(_ view: NSView, in rect: NSRect, matching color: NSColor) throws -> Double {
    view.displayIfNeeded()
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
    view.cacheDisplay(in: rect, to: rep)
    return try share(of: color, in: rep, as: view)
}

@MainActor
private func share(of color: NSColor, in rep: NSBitmapImageRep, as view: NSView) throws -> Double {
    var target: NSColor?
    view.effectiveAppearance.performAsCurrentDrawingAppearance { target = color.usingColorSpace(.deviceRGB) }
    let wanted = try #require(target)
    var matches = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let pixel = rep.colorAt(x: x, y: y) else { continue }
            if abs(pixel.redComponent - wanted.redComponent) < 0.04,
                abs(pixel.greenComponent - wanted.greenComponent) < 0.04,
                abs(pixel.blueComponent - wanted.blueComponent) < 0.04
            {
                matches += 1
            }
        }
    }
    return Double(matches) / Double(max(1, rep.pixelsWide * rep.pixelsHigh))
}

/// The empty line after the end of the text, as the writer sees it: the caret there, and where
/// the page ends, with the caret anywhere. Nothing here lays the page out: TextKit lays that line
/// out in the typing attributes, and a forced layout can put it somewhere the screen doesn't.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct EndLineTests {
    @Test(
        arguments: [[[Run("Hello")], []], [[Run("A")], [], [Run("B")], []], [] as [Paragraph]]
            as [[Paragraph]])
    func theEndLineIsWhereTheMultiplePutItWhereverTheCaretIs(body: [Paragraph]) async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            try await expectTheEndLineWhereTheMultiplePutIt(page)
        }
    }

    /// Text ending in an empty paragraph (Return twice at the end; #102), however many, and an
    /// empty paragraph alone, where TextKit put the end line straight under the empty one.
    @Test(
        arguments: [[[Run("Hello")], [], []], [[Run("A")], [], [], []], [[], []]] as [[Paragraph]])
    func afterAFinalEmptyParagraph(body: [Paragraph]) async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            try #require(page.storage.string.hasSuffix("\n\n") || page.storage.string == "\n", "precondition")
            try await expectTheEndLineWhereTheMultiplePutIt(page)
        }
    }

    /// Up from the end line after a final empty paragraph goes to that paragraph, and Down comes
    /// back: the arrows move through the placed line as through TextKit's own.
    @Test func theArrowsMoveBetweenAFinalEmptyParagraphAndTheEndLine() async throws {
        try await withPage([scene("One", [[Run("Hello")], [], []])], in: KeyWindow.self) { page in
            let end = page.storage.length
            try #require(page.storage.string == "Hello\n\n", "precondition")
            _ = try await keyAndFocused(page, at: end)
            page.page.moveUp(nil)
            #expect(page.page.selectedRange() == NSRange(location: end - 1, length: 0))
            page.page.moveDown(nil)
            #expect(page.page.selectedRange() == NSRange(location: end, length: 0))
            page.page.moveUp(nil)
            page.page.moveUp(nil)
            #expect(page.page.selectedRange().location <= 5, "on up to Hello: \(page.page.selectedRange())")
        }
    }

    /// A click on the end line, or in the spacing above it (which the multiple put inside it),
    /// puts the caret at the end; a click on the empty paragraph, in it.
    @Test func aClickOnOrJustAboveTheEndLinePutsTheCaretAtTheEnd() async throws {
        try await withPage([scene("One", [[Run("Hello")], [], []])], in: KeyWindow.self) { page in
            let end = page.storage.length
            let atEnd = try await keyAndFocused(page, at: end)
            let inEmpty = try await keyAndFocused(page, at: end - 1)
            let gap = ParagraphRole.doubleSpacingGap
            try #require(
                abs(atEnd.minY - (inEmpty.maxY + gap)) < 0.01,
                "precondition: the gap between \(inEmpty), \(atEnd)")
            let x = atEnd.minX + 1
            for (y, expected) in [
                (inEmpty.midY, end - 1), (inEmpty.maxY + gap / 2, end), (atEnd.midY, end),
            ] {
                #expect(
                    page.page.characterIndexForInsertion(at: NSPoint(x: x, y: y)) == expected,
                    "at \(y), between \(inEmpty) and \(atEnd)")
            }
        }
    }

    /// #102 as the writer met it: Return pressed twice at the end of the text.
    @Test func afterReturnTwiceAtTheEnd() async throws {
        try await withPage([scene("One", [[Run("Hello")]])], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: 5)
            let caret = try systemCaret(of: page)
            page.page.insertNewline(nil)
            page.page.insertNewline(nil)
            try #require(page.storage.string == "Hello\n\n", "precondition: two Returns at the end")
            #expect(page.pageMirrorsModel)
            let expected = try endLine(of: try multipleSpaced(page.page))
            // The system moves its caret on a later turn of the run loop.
            await eventually { abs(caret.frame.minY - expected.caretTop) < 0.01 && !caret.isHidden }
            #expect(abs(caret.frame.minY - expected.caretTop) < 0.01, "\(caret.frame) vs \(expected)")
            #expect(abs(caret.frame.height - (try singleSpacedLine()).height) < 0.01, "\(caret.frame)")
            try await expectTheEndLineWhereTheMultiplePutIt(page)
            try await expectCaretFitsTypedText(page, at: page.storage.length)
        }
    }

    @MainActor
    private func expectTheEndLineWhereTheMultiplePutIt(
        _ page: PageHarness, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let expected = try endLine(of: try multipleSpaced(page.page))
        let seen = try await whatTheWriterSees(page)
        #expect(
            seen.caretsAtTheEnd.allSatisfy { abs($0 - expected.caretTop) < 0.01 }, "\(seen) vs \(expected)",
            sourceLocation: sourceLocation)
        #expect(
            seen.pageEnds.allSatisfy { abs($0 - expected.bottom) < 0.01 }, "\(seen) vs \(expected)",
            sourceLocation: sourceLocation)
    }

    /// The caret's top each time it's at the end, and where the page's text ends, as the caret goes
    /// from the end to the start, an empty paragraph if there is one, and back.
    @MainActor
    private func whatTheWriterSees(_ page: PageHarness) async throws -> (
        caretsAtTheEnd: [CGFloat], pageEnds: [CGFloat]
    ) {
        let string = page.storage.string as NSString
        let end = string.length
        var places = [end, 0, end]
        if let empty = (0..<end).first(where: { ParagraphContent(ofParagraphAt: $0, in: string) == .empty }) {
            places += [empty, end, empty]
        }
        var carets: [CGFloat] = []
        var ends: [CGFloat] = []
        let layout = try #require(page.page.textLayoutManager)
        for place in places {
            let caret = try await keyAndFocused(page, at: place)
            page.window.displayIfNeeded()
            if place == end { carets.append(caret.minY) }
            ends.append(page.page.textContainerOrigin.y + layout.usageBoundsForTextContainer.maxY)
        }
        return (carets, ends)
    }

    /// The page's text as `lineHeightMultiple = 2` laid it out, in a view of its own.
    @MainActor
    private func multipleSpaced(_ page: ManuscriptTextView) throws -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: true)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.size = try #require(page.textContainer?.size)
        view.frame = page.frame
        view.textContainerInset = NSSize(
            width: page.textContainerInset.width,
            height: page.textContainerInset.height - ParagraphRole.doubleSpacingGap)
        let doubled = NSMutableParagraphStyle()
        doubled.lineHeightMultiple = 2
        doubled.firstLineHeadIndent = 36
        let text = NSMutableAttributedString(attributedString: try #require(page.textStorage))
        text.addAttribute(.paragraphStyle, value: doubled, range: NSRange(location: 0, length: text.length))
        view.textStorage?.setAttributedString(text)
        var typing = ParagraphRole.body.typingAttributes
        typing[.paragraphStyle] = doubled
        view.typingAttributes = typing
        return view
    }

    /// Where the multiple put the end line: where a text-height caret on it starts, and its bottom.
    @MainActor
    private func endLine(of view: NSTextView) throws -> (caretTop: CGFloat, bottom: CGFloat) {
        let layout = try #require(view.textLayoutManager)
        var last: (CGFloat, CGFloat)?
        let origin = view.textContainerOrigin
        layout.enumerateTextLayoutFragments(
            from: layout.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            if let line = fragment.textLineFragments.last {
                let top = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
                last = (top + line.glyphOrigin.y, top + line.typographicBounds.height)
            }
            return true
        }
        let found = try #require(last)
        return (found.0 - (try singleSpacedLine()).baselineOffset, found.1)
    }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct HighlightSelectionTests {
    /// The owner's pick (ADR 0034): inside the selection the selection's colour replaces a
    /// highlight; outside it the highlight keeps its own.
    @Test func theSelectionColourReplacesTheHighlightInsideTheSelection() async throws {
        let body: [Paragraph] = [
            [
                Run("Plain words, then "), Run("a highlighted phrase in green", highlight: .green),
                Run(" and plain again."),
            ]
        ]
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            try await settle(page, at: .standard)
            let view = page.page
            let string = page.storage.string as NSString
            let highlighted = string.range(of: "a highlighted phrase in green")
            let green = try #require(
                page.storage.attribute(.backgroundColor, at: highlighted.location, effectiveRange: nil)
                    as? NSColor)
            let selected = NSRange(location: 6, length: highlighted.location + 10 - 6)
            page.focusPage(at: 0)
            try expectBands(view, selecting: selected, lines: 1)
            let inside = try textRect(NSRange(location: highlighted.location + 2, length: 6), in: view)
            let outside = try textRect(NSRange(location: highlighted.location + 14, length: 8), in: view)
            let selection = try await composited(view, in: inside, matching: .selectedTextBackgroundColor)
            #expect(selection > 0.3, "the selected part of the highlight shows the selection: \(selection)")
            let kept = try await composited(view, in: outside, matching: green)
            #expect(kept > 0.3, "the rest keeps its highlight: \(kept)")
            page.window.makeFirstResponder(page.title)
            let inactive = try await composited(
                view, in: inside, matching: .unemphasizedSelectedTextBackgroundColor)
            #expect(inactive > 0.3, "and the grey selection without the focus: \(inactive)")
        }
    }

    /// Across a green highlight, then collapsed: the green is back and no selection colour is
    /// left, after a plain collapse, an edit before the selection, an undo, and a scene switch.
    @Test(arguments: [Collapse.plain, .afterAnEditBefore, .afterUndo, .afterASceneSwitch])
    func noSelectionColourOutlivesTheSelection(_ how: Collapse) async throws {
        let body: [Paragraph] = [
            [
                Run("Plain words, then "), Run("a highlighted phrase in green", highlight: .green),
                Run(" and plain again."),
            ]
        ]
        let one = scene("One", body)
        // Shorter, its highlight elsewhere: what was set for the first scene can't fit it.
        let two = scene("Two", [[Run("Hi, "), Run("a highlighted phrase in green", highlight: .green)]])
        try await withPage([one, two], in: KeyWindow.self) { page in
            try await settle(page, at: .standard)
            let view = page.page
            let highlighted = (page.storage.string as NSString).range(of: "a highlighted phrase in green")
            page.focusPage(at: 0)
            view.setSelectedRange(NSRange(location: 6, length: highlighted.location + 10 - 6))
            let inside = try textRect(NSRange(location: highlighted.location + 2, length: 6), in: view)
            let selected = try await composited(view, in: inside, matching: .selectedTextBackgroundColor)
            try #require(selected > 0.3, "precondition: the selection shows over the highlight: \(selected)")
            switch how {
            case .plain:
                view.setSelectedRange(NSRange(location: 0, length: 0))
            case .afterAnEditBefore:
                view.insertText("Now. ", replacementRange: NSRange(location: 0, length: 0))
                view.setSelectedRange(NSRange(location: 0, length: 0))
            case .afterUndo:
                view.insertText("Now. ", replacementRange: NSRange(location: 0, length: 0))
                view.breakUndoCoalescing()
                await undoInAnEvent(try #require(view.undoManager))
                view.setSelectedRange(NSRange(location: 0, length: 0))
            case .afterASceneSwitch:
                page.book.select(two.id)
                await eventually { page.book.openScene == two.id && page.pageMirrorsModel }
            }
            let now = (page.storage.string as NSString).range(of: "a highlighted phrase in green")
            let green = try #require(
                page.storage.attribute(.backgroundColor, at: now.location, effectiveRange: nil) as? NSColor)
            let phrase = try textRect(now, in: view)
            let kept = try await composited(view, in: phrase, matching: green)
            #expect(kept > 0.3, "the green is back: \(kept)")
            for color in [NSColor.selectedTextBackgroundColor, .unemphasizedSelectedTextBackgroundColor] {
                let left = try await composited(view, in: phrase, matching: color)
                #expect(left < 0.01, "no selection colour is left on the highlight: \(left)")
            }
            let line = try textRect(NSRange(location: 0, length: page.storage.length), in: view)
            let accent = try await composited(view, in: line, matching: .selectedTextBackgroundColor)
            #expect(accent < 0.01, "nor anywhere on the line: \(accent)")
            let layout = try #require(view.textLayoutManager)
            var overrides = 0
            layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) {
                _, attributes, _ in
                if attributes[.backgroundColor] != nil { overrides += 1 }
                return true
            }
            #expect(overrides == 0, "and no selection colour is kept for later: \(overrides)")
        }
    }

    enum Collapse: CustomTestStringConvertible {
        case plain, afterAnEditBefore, afterUndo, afterASceneSwitch

        var testDescription: String { "\(self)" }
    }

    /// The glyphs' extent of `range` on one line, a little inside, in the view's coordinates.
    @MainActor
    private func textRect(_ range: NSRange, in view: NSTextView) throws -> NSRect {
        let layout = try #require(view.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let start = try #require(content.location(content.documentRange.location, offsetBy: range.location))
        let end = try #require(content.location(start, offsetBy: range.length))
        var rect: NSRect?
        layout.enumerateTextSegments(
            in: try #require(NSTextRange(location: start, end: end)), type: .standard, options: []
        ) { _, frame, _, _ in
            rect = frame
            return false
        }
        let origin = view.textContainerOrigin
        let found = try #require(rect).offsetBy(dx: origin.x, dy: origin.y)
        // The highlight is the glyphs' height, inside the line.
        return found.insetBy(dx: 2, dy: found.height * 0.35)
    }
}
