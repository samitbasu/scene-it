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
    let fragment = try #require(layout.textLayoutFragment(for: start))
    let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
    let lines = fragment.textLineFragments
    let index = try #require(
        lines.firstIndex { NSLocationInRange(location - offset, $0.characterRange) },
        "a line holds \(location)")
    let line = lines[index]
    let origin = page.textContainerOrigin
    let x = line.locationForCharacter(at: location - offset).x
    return (
        origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y,
        origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + x,
        index == 0
    )
}

@MainActor
private func caret(of page: PageHarness) throws -> CaretIndicator {
    try #require(page.page.caret, "the page has its caret")
}

/// The text view's own caret: the indicator under the page that isn't ours.
@MainActor
private func systemCaret(of page: PageHarness) throws -> NSTextInsertionIndicator {
    let ours = try caret(of: page).indicator
    let others = subviewTree(of: page.page).compactMap { $0 as? NSTextInsertionIndicator }.filter {
        $0 !== ours
    }
    try #require(others.count == 1, "precondition: the text view has one caret of its own")
    return others[0]
}

/// Our caret is where the text view puts its own: the same x, and the same bottom, since
/// double spacing puts the line's extra height above the letters.
@MainActor
private func expectCaretMatchesTheSystemCaret(
    _ page: PageHarness, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let ours = try caret(of: page).frame
    let system = try systemCaret(of: page).frame
    #expect(abs(ours.minX - system.minX) < 0.01, "x: \(ours) vs \(system)", sourceLocation: sourceLocation)
    #expect(
        abs(ours.maxY - system.maxY) < 0.01, "bottom: \(ours) vs \(system)", sourceLocation: sourceLocation)
}

@MainActor
private func keyAndFocused(_ page: PageHarness, at location: Int) async throws -> NSRect {
    try #require(page.window.isKeyWindow, "precondition: a key window")
    page.focusPage(at: location)
    let caret = try caret(of: page)
    await eventually { caret.isShown }
    try #require(caret.isShown, "precondition: the caret shows")
    return caret.frame
}

/// The caret at `location` is exactly where a letter typed there sits: at its leading edge, and
/// as tall as a single-spaced line around its baseline.
@MainActor
private func expectCaretFitsTypedText(
    _ page: PageHarness, at location: Int, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let caret = try await keyAndFocused(page, at: location)
    page.page.insertText("x", replacementRange: NSRange(location: location, length: 0))
    let typed = try glyphLine(at: location, in: page.page)
    let single = try singleSpacedLine()
    #expect(abs(caret.minX - typed.x) < 0.01, "at the letter's leading edge", sourceLocation: sourceLocation)
    #expect(
        abs(caret.minY - (typed.baseline - single.baselineOffset)) < 0.01, "top: \(caret) for \(typed)",
        sourceLocation: sourceLocation)
    #expect(
        abs(caret.height - single.height) < 0.01, "a single-spaced line tall", sourceLocation: sourceLocation)
    #expect(
        try systemCaret(of: page).color.alphaComponent == 0, "the text view's own caret is clear",
        sourceLocation: sourceLocation)
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
            let onScreen = page.page.convert(try caret(of: page).frame, to: nil)
            let single = try singleSpacedLine()
            #expect(abs(onScreen.height - single.height * Double(zoom)) < 0.01, "it scales with the zoom")
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

    @Test func followsTheCaretAsItMoves() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            let first = try await keyAndFocused(page, at: 0)
            let ours = try caret(of: page)
            page.page.moveDown(nil)
            await eventually { ours.frame.minY > first.minY }
            #expect(ours.frame.minY > first.minY)
            #expect(abs(ours.frame.height - first.height) < 0.01)
        }
    }

    @Test func hiddenWithARangeSelected() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: 0)
            let ours = try caret(of: page)
            page.page.setSelectedRange(NSRange(location: 0, length: 3))
            #expect(!ours.isShown)
            page.page.setSelectedRange(NSRange(location: 3, length: 0))
            #expect(ours.isShown)
        }
    }

    @Test func hiddenWhenThePageLosesTheFocusOrTheWindowIsNotKey() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: 0)
            let ours = try caret(of: page)
            page.window.makeFirstResponder(page.title)
            let shownWithTheTitleFocused = ours.isShown
            #expect(
                !shownWithTheTitleFocused,
                "the title has the focus \(String(describing: page.window.firstResponder))")
            page.focusPage(at: 0)
            #expect(ours.isShown)
            KeyWindow.isKey = false
            defer { KeyWindow.isKey = true }
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: page.window)
            #expect(!ours.isShown, "another window is key")
            KeyWindow.isKey = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: page.window)
            #expect(ours.isShown)
        }
    }

    @Test func hiddenWhenThePageIsReadOnly() async throws {
        try await withPage([scene("Held", [[Run("Kept.")]])], holdingTheLock: true, in: KeyWindow.self) {
            page in
            page.focusPage(at: 2)
            try #require(!page.page.isEditable, "precondition: read-only")
            try #require(page.window.firstResponder === page.page, "precondition: the page has the focus")
            #expect(!(try caret(of: page).isShown))
        }
    }

    @Test func atTheEndOfAWrappedLine() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            let layout = try #require(page.page.textLayoutManager)
            let first = try #require(layout.textLayoutFragment(for: layout.documentRange.location))
            let lineEnd = try #require(first.textLineFragments.first).characterRange.upperBound
            try #require(first.textLineFragments.count > 1, "precondition: the paragraph wraps")
            _ = try await keyAndFocused(page, at: lineEnd)
            page.page.setSelectedRange(
                NSRange(location: lineEnd, length: 0), affinity: .downstream, stillSelecting: false)
            let downstream = try caret(of: page).frame
            try expectCaretMatchesTheSystemCaret(page)
            page.page.setSelectedRange(
                NSRange(location: lineEnd, length: 0), affinity: .upstream, stillSelecting: false)
            let upstream = try caret(of: page).frame
            try #require(
                upstream.minY < downstream.minY,
                "precondition: upstream is on the line above: \(upstream) \(downstream) system \(String(describing: try? systemCaret(of: page).frame)) lineEnd \(lineEnd)"
            )
            try expectCaretMatchesTheSystemCaret(page)
            #expect(abs(upstream.height - downstream.height) < 0.01)
        }
    }

    /// A layout pass that moves the caret's line, with the selection unmoved. (Placing the caret
    /// lays out everything above it, so no estimate is left to replace; a narrower column rewraps
    /// the paragraph above, which no selection or frame hook sees.)
    @Test func followsALineThatLayoutMoves() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: (long as NSString).length + 2 + 3)
            let ours = try caret(of: page)
            let system = try systemCaret(of: page)
            let before = system.frame
            let container = try #require(page.page.textContainer)
            container.size = NSSize(width: container.size.width / 2, height: container.size.height)
            await eventually { system.frame.minY > before.minY }
            try #require(system.frame.minY > before.minY, "precondition: the line moved down")
            await eventually { abs(ours.frame.maxY - system.frame.maxY) < 0.01 }
            try expectCaretMatchesTheSystemCaret(page)
        }
    }

    @Test func followsTheTypingFont() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: 5)
            var attributes = page.page.typingAttributes
            attributes[.font] = NSFont(name: ParagraphRole.fontFamily, size: 24)
            page.page.typingAttributes = attributes
            #expect(try caret(of: page).frame.height > 20, "the caret grew with the typing font at once")
        }
    }

    @Test func appearsWhenTheFocusedPageBecomesEditable() async throws {
        try await withPage([scene("Held", [[Run("Kept.")]])], holdingTheLock: true, in: KeyWindow.self) {
            page in
            page.focusPage(at: 2)
            try #require(!page.page.isEditable, "precondition: read-only")
            try #require(page.window.firstResponder === page.page, "precondition: the page has the focus")
            try #require(!(try caret(of: page).isShown), "precondition: no caret while read-only")
            let editor = try #require(page.page.editor)
            editor.show(try #require(page.book.openScene), .editable)
            #expect(try caret(of: page).isShown)
            try expectCaretMatchesTheSystemCaret(page)
        }
    }

    @Test func followsASceneSwitch() async throws {
        let one = scene("One", body)
        let two = scene("Two", [[Run("Second.")]])
        try await withPage([one, two], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: 5)
            page.book.select(two.id)
            await eventually { page.storage.string == "Second." }
            try expectCaretMatchesTheSystemCaret(page)
        }
    }

    @Test func followsAModelReload() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: 5)
            page.book.replaceBody(of: try #require(page.book.openScene), with: [[Run("Replaced.")], []])
            await eventually { page.storage.string == "Replaced.\n" }
            try expectCaretMatchesTheSystemCaret(page)
        }
    }

    @Test func followsUndoAndRedo() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: 0)
            page.page.insertParagraphSeparator(nil)
            page.page.breakUndoCoalescing()
            let undo = try #require(page.page.undoManager)
            await undoInAnEvent(undo)
            try expectCaretMatchesTheSystemCaret(page)
            await undoInAnEvent(undo, .redo)
            try expectCaretMatchesTheSystemCaret(page)
        }
    }

    @Test func theFontsOwnMetricsAreAFallbackOfAboutTheSameSize() throws {
        let font = ParagraphRole.body.font([])
        let laidOut = SingleSpacedLine(font)
        let fallback = SingleSpacedLine(metricsOf: font)
        #expect(fallback.height > 0 && abs(fallback.height - laidOut.height) < 1)
        #expect(fallback.ascent > 0 && abs(fallback.ascent - laidOut.ascent) < 1)
    }
}
