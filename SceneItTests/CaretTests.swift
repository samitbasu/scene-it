import AppKit
import SceneItCore
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
    let touched = try laidOutLines(of: view).filter { NSIntersectionRange($0.range, range).length > 0 }
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
    @Test func aFoundMatchShowsAsItsBand() async throws {
        try await withPage([scene("One", selectionBody)], in: KeyWindow.self) { page in
            page.focusPage(at: 0)
            let match = (page.storage.string as NSString).range(of: "dawn")
            try #require(match.location != NSNotFound, "precondition: a match")
            page.page.setSelectedRange(match)
            page.page.showFindIndicator(for: match)
            try expectBands(page.page, selecting: match, lines: 1)
        }
    }
}
