import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

private let early = CommentID(rawValue: "01JC4K0000000000000000EARL")
private let gone = CommentID(rawValue: "01JC4K0000000000000000GONE")

/// The letter's comment (`noted`, created first) comes after the dawn's (`early`) on the page,
/// and `gone` covers nothing.
private let panelScene: [Paragraph] = [
    [Run("Dawn", comments: [early]), Run(" came. The "), Run("letter", comments: [noted]), Run(" waited.")]
]
private let letterRange = NSRange(location: 15, length: 6)

private func panelBook() -> BookScene {
    var commented = scene("One", panelScene)
    let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_100), in: .gmt)
    commented.comments = [
        tooEarly, Comment(id: early, color: .red, text: "At dawn?", created: created),
        Comment(id: gone, color: .gray, text: "Cut?", created: created),
    ]
    return commented
}

/// The comments panel (#25) in the real window: its cards, both ways of selecting, typing in a
/// card, the ⋯ menu's ⌫, and the + and floating buttons' shared enabled state.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct CommentsPanelTests {
    @Test func theCardsAreInTextOrderWithTheDetachedLast() async throws {
        try await withPanel { harness in
            await eventually { harness.cards.count == 3 }
            let byPosition = harness.cards.sorted {
                $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY
            }
            #expect(byPosition.map(\.comment) == [early, noted, gone])
            #expect(byPosition.map(\.string) == ["At dawn?", "Too early?", "Cut?"])
        }
    }

    /// A click on underlined text selects its card; a card taking the focus (a click on it)
    /// selects it and its text on the page.
    @Test func selectingWorksBothWays() async throws {
        try await withPanel { harness in
            let editor = try #require(harness.page.editor)
            let scene = try #require(harness.book.openScene)
            try #require(
                (harness.storage.string as NSString).substring(with: letterRange) == "letter", "precondition")
            harness.focusPage(at: letterRange.location + 2)
            editor.clickedComments(at: letterRange.location + 2)
            #expect(editor.comments.comment(in: scene) == noted)

            await eventually { harness.card(early) != nil }
            let card = try #require(harness.card(early))
            #expect(harness.window.makeFirstResponder(card))
            #expect(editor.comments.comment(in: scene) == early)
            #expect(harness.page.selectedRanges.map(\.rangeValue) == [NSRange(location: 0, length: 4)])
            #expect(harness.window.firstResponder === card, "the focus stays in the card")
        }
    }

    /// A card's typing reaches the model at once with no undo step; leaving the card makes it
    /// one step on the page's undo, which undoes back to the text it began with.
    @Test func typingInACardIsKeptAtOnceAndUndoneAsOneStep() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            let pageUndo = harness.book.pageUndo(for: scene)
            await eventually { harness.card(noted) != nil }
            let card = try #require(harness.card(noted))
            #expect(harness.window.makeFirstResponder(card))
            card.setSelectedRange(NSRange(location: (card.string as NSString).length, length: 0))
            card.insertText(" Or late", replacementRange: card.selectedRange())
            card.insertText("\u{2014}why?", replacementRange: card.selectedRange())
            #expect(harness.text(of: noted) == "Too early? Or late--why?", "drafted, through the policy")
            #expect(!pageUndo.canUndo, "no step yet")
            #expect(card.undoManager?.canUndo == true, "the card's own typing history")

            harness.focusPage(at: 0)
            #expect(pageUndo.undoActionName == CommentWording.editUndoName)
            #expect(card.undoManager?.canUndo == false, "the card's history goes with the edit")
            pageUndo.undo()
            #expect(harness.text(of: noted) == "Too early?")
            #expect(!pageUndo.canUndo, "one step")
            await eventually { harness.card(noted)?.string == "Too early?" }
            pageUndo.redo()
            #expect(harness.text(of: noted) == "Too early? Or late--why?")
            await eventually { harness.book.status == .saved }
            #expect(try bookOnDisk(harness.url) == harness.book.book)
        }
    }

    /// ⌫ while the ⋯ menu is open dismisses the comment, its underline with it; undo restores both.
    @Test func backspaceInTheOpenMenuDismissesAndUndoRestores() async throws {
        try await withPanel { harness in
            let editor = try #require(harness.page.editor)
            let scene = try #require(harness.book.openScene)
            editor.comments.select(noted, in: scene)
            editor.comments.openMenu(of: noted, in: scene)
            await eventually { harness.popover != nil }
            let popover = try #require(harness.popover)
            let backspace = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: popover.windowNumber, context: nil, characters: "\u{7F}",
                    charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51))
            #expect(popover.performKeyEquivalent(with: backspace))
            #expect(harness.book.book.scene(scene)?.comments.map(\.id) == [early, gone])
            #expect(harness.storage.ranges(commentedBy: noted).isEmpty)
            await eventually { harness.popover == nil && harness.card(noted) == nil }

            let pageUndo = harness.book.pageUndo(for: scene)
            #expect(pageUndo.undoActionName == CommentWording.dismissUndoName)
            pageUndo.undo()
            #expect(harness.book.book.scene(scene)?.comments.map(\.id) == [noted, early, gone])
            #expect(harness.storage.ranges(commentedBy: noted) == [letterRange])
            await eventually { harness.card(noted) != nil && harness.page.commentPalette.covers(noted) }
        }
    }

    /// The owner's rule: a new comment needs a selection. The + button, the floating button and
    /// Edit → New Comment all ask `EditorFormatting.commentablePage`; the floating button shows
    /// only while it answers, and a new comment's card takes the focus.
    @Test func aNewCommentNeedsASelectionAndOpensItsCard() async throws {
        try await withPanel { harness in
            harness.focusPage(at: 2)
            await eventually { harness.formatting.page != nil }
            #expect(harness.formatting.commentablePage == nil, "a caret isn't enough")
            #expect(harness.page.commentButton.isHidden)

            harness.page.setSelectedRange(NSRange(location: 5, length: 4))
            #expect(harness.formatting.commentablePage === harness.page.editor)
            #expect(!harness.page.commentButton.isHidden)
            let band = try #require(harness.page.selectionBands.last)
            #expect(harness.page.commentButton.frame.minY >= band.maxY, "below the selection's end")

            harness.preferences.showRightPanelTab(.notes)
            let id = try #require(harness.formatting.commentablePage?.newCommentInItsCard())
            #expect(harness.preferences.rightPanelTab == .comments, "the panel shows the new card")
            await eventually { harness.window.firstResponder === harness.card(id) }
            #expect(harness.formatting.commentablePage == nil, "the page has lost the focus")
            #expect(harness.page.commentButton.isHidden)
        }
    }

    @Test func aReadOnlyBookShowsCardsThatCantBeEdited() async throws {
        try await withPanel(holdingTheLock: true) { harness in
            await eventually { harness.cards.count == 3 }
            #expect(harness.cards.allSatisfy { !$0.isEditable && $0.isSelectable })
            harness.page.setSelectedRange(NSRange(location: 5, length: 4))
            #expect(harness.formatting.commentablePage == nil)
            #expect(harness.page.commentButton.isHidden)
        }
    }

    /// A card's text refuses drag and drop, as the page does (ADR 0036).
    @Test func aCardRefusesDragAndDrop() async throws {
        try await withPanel { harness in
            await eventually { harness.card(noted) != nil }
            let card = try #require(harness.card(noted))
            try await card.expectRefusesEveryDrop()
            #expect(harness.window.makeFirstResponder(card))
            card.setSelectedRange(NSRange(location: 0, length: 3))
            try card.expectRefusesToDragItsSelection(pressedThrough: .selectionManager)
        }
    }

    private func withPanel(holdingTheLock: Bool = false, _ body: (PageHarness) async throws -> Void)
        async throws
    {
        try await withPage([panelBook()], holdingTheLock: holdingTheLock) { harness in
            harness.preferences.reveal(.comments)
            try await body(harness)
        }
    }
}

extension PageHarness {
    var cards: [CommentTextView] {
        subviewTree(of: window.contentView).compactMap { $0 as? CommentTextView }
    }

    func card(_ comment: CommentID) -> CommentTextView? {
        cards.first { $0.comment == comment }
    }

    func text(of comment: CommentID) -> String? {
        book.book.scene(book.openScene)?.comments.first { $0.id == comment }?.text
    }

    /// The ⋯ menu's popover window, while it's up.
    var popover: NSWindow? {
        NSApp.windows.first { $0 !== window && $0.isVisible && $0.className.contains("Popover") }
    }
}
