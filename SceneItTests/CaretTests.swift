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
