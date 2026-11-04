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
        origin.x + fragment.layoutFragmentFrame.minX + x,
        index == 0
    )
}

@MainActor
private func keyAndFocused(_ page: PageHarness, at location: Int) async throws -> NSRect {
    try #require(page.window.isKeyWindow, "precondition: a key window")
    page.focusPage(at: location)
    await eventually { page.page.caret.isShown }
    try #require(page.page.caret.isShown, "precondition: the caret shows")
    return page.page.caret.frame
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
    let systemCarets = subviewTree(of: page.page).compactMap { $0 as? NSTextInsertionIndicator }
    try #require(systemCarets.count == 2, "precondition: the text view's caret and ours")
    for indicator in systemCarets where indicator.frame != page.page.caret.frame {
        #expect(
            indicator.color.alphaComponent == 0, "the text view's own caret is clear",
            sourceLocation: sourceLocation)
    }
}

private let long =
    "The ferry left before dawn, and nobody on the quay said a word about the letter that had come "
    + "for her in the night, though everyone had seen the boy run down the hill with it."

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
    @Test(arguments: [1.0, 2.0])
    func onATextLine(zoom: Double) async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            try await settle(page, at: Zoom(clamping: zoom))
            try #require(try glyphLine(at: 5, in: page.page).isFirstLine, "precondition: the first line")
            try await expectCaretFitsTypedText(page, at: 5)
            let onScreen = page.page.convert(page.page.caret.frame, to: nil)
            let single = try singleSpacedLine()
            #expect(abs(onScreen.height - single.height * zoom) < 0.01, "it scales with the zoom")
        }
    }

    @Test(arguments: [1.0, 2.0])
    func onAWrappedLine(zoom: Double) async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            try await settle(page, at: Zoom(clamping: zoom))
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
            page.page.moveDown(nil)
            await eventually { page.page.caret.frame.minY > first.minY }
            #expect(page.page.caret.frame.minY > first.minY)
            #expect(abs(page.page.caret.frame.height - first.height) < 0.01)
        }
    }

    @Test func hiddenWithARangeSelected() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: 0)
            page.page.setSelectedRange(NSRange(location: 0, length: 3))
            #expect(!page.page.caret.isShown)
            page.page.setSelectedRange(NSRange(location: 3, length: 0))
            #expect(page.page.caret.isShown)
        }
    }

    @Test func hiddenWhenThePageLosesTheFocusOrTheWindowIsNotKey() async throws {
        try await withPage([scene("One", body)], in: KeyWindow.self) { page in
            _ = try await keyAndFocused(page, at: 0)
            page.window.makeFirstResponder(page.title)
            let shownWithTheTitleFocused = page.page.caret.isShown
            #expect(
                !shownWithTheTitleFocused,
                "the title has the focus \(String(describing: page.window.firstResponder))")
            page.focusPage(at: 0)
            #expect(page.page.caret.isShown)
            KeyWindow.isKey = false
            defer { KeyWindow.isKey = true }
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: page.window)
            #expect(!page.page.caret.isShown, "another window is key")
            KeyWindow.isKey = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: page.window)
            #expect(page.page.caret.isShown)
        }
    }

    @Test func hiddenWhenThePageIsReadOnly() async throws {
        try await withPage([scene("Held", [[Run("Kept.")]])], holdingTheLock: true, in: KeyWindow.self) {
            page in
            page.focusPage(at: 2)
            try #require(!page.page.isEditable, "precondition: read-only")
            try #require(page.window.firstResponder === page.page, "precondition: the page has the focus")
            #expect(!page.page.caret.isShown)
        }
    }
}
