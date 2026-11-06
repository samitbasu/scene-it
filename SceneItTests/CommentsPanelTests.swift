import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt
@testable import SceneItCore

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
            let card = try await harness.typeInCard(noted, " Or late", "\u{2014}why?")
            #expect(harness.text(of: noted) == "Too early? Or late--why?", "drafted, through the policy")
            #expect(!pageUndo.canUndo, "no step yet")
            #expect(card.undoManager?.canUndo == true, "the card's own typing history")

            harness.focusPage(at: 0)
            #expect(pageUndo.undoActionName == CommentWording.editUndoName)
            #expect(card.undoManager?.canUndo == false, "the card's history goes with the edit")
            try harness.undoOnThePage()
            #expect(harness.text(of: noted) == "Too early?")
            #expect(!pageUndo.canUndo, "one step")
            await eventually { harness.card(noted)?.string == "Too early?" }
            try harness.undo.redo()
            #expect(harness.text(of: noted) == "Too early? Or late--why?")
            await eventually { harness.book.status == .saved }
            #expect(try bookOnDisk(harness.url) == harness.book.book)
        }
    }

    /// Esc ends a card's edit and hands the focus to the page, where Undo undoes the edit.
    @Test func escHandsTheFocusToThePageWhereUndoUndoesTheEdit() async throws {
        try await withPanel { harness in
            let card = try await harness.typeInCard(noted, " Really?")
            card.cancelOperation(nil)
            #expect(harness.window.firstResponder === harness.page)
            #expect(
                harness.book.pageUndo(for: try #require(harness.book.openScene)).undoActionName
                    == CommentWording.editUndoName)
            try harness.undoOnThePage()
            #expect(harness.text(of: noted) == "Too early?")
        }
    }

    /// The review's case (#25): type, recolor from the menu, type more, leave, then undo twice:
    /// each undo takes back only its own field, so the original text and color come back, and no
    /// half-typed draft is left.
    @Test func undoingAnEditAndARecolorMadeDuringItRestoresBoth() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            let card = try await harness.typeInCard(noted, " Or")
            let menu = try await harness.menu(of: noted, in: scene)
            try perform(try #require(menu.items.first { CommentMenu.color(of: $0) == .green }))
            card.insertText(" late?", replacementRange: card.selectedRange())
            #expect(harness.window.firstResponder === card, "the menu leaves the focus in the card")
            harness.focusPage(at: 0)
            #expect(harness.book.book.scene(scene)?.comment(noted)?.text == "Too early? Or late?")
            #expect(harness.book.book.scene(scene)?.comment(noted)?.color == .green)
            try harness.undoOnThePage()
            try harness.undoOnThePage()
            #expect(harness.book.book.scene(scene)?.comment(noted) == tooEarly)
        }
    }

    /// The owner's bug A (#25): a recolor while the card has the focus mid-draft shows at once,
    /// on the card's stripe, the page's underline and the menu's check mark.
    @Test func aRecolorMidDraftShowsAtOnce() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            let card = try await harness.typeInCard(noted, " Or")
            try #require(harness.underlineColor(of: letterRange) == .purple, "precondition")
            try await harness.settle(drawing: .purple, under: letterRange)
            try #require(try harness.stripeColor(of: card)?.isClose(to: .purple) == true, "precondition")
            // As the ⋯ control opens it: choosing waits until the menu has closed.
            await eventually { harness.menuControl(of: noted) != nil }
            let control = try #require(harness.menuControl(of: noted))
            let menu = try #require(control.openingMenu())
            try perform(try #require(menu.items.first { CommentMenu.color(of: $0) == .red }))
            #expect(harness.book.book.scene(scene)?.comment(noted)?.color == .purple, "not while it's open")
            control.runChosen()
            #expect(harness.book.book.scene(scene)?.comment(noted)?.color == .red)
            #expect(harness.underlineColor(of: letterRange) == .red, "the page's underline at once")
            #expect(harness.window.firstResponder === card, "no change of focus")
            try await harness.expectDrawn(.red, not: .purple, under: letterRange)
            await eventually { (try? harness.stripeColor(of: card))??.isClose(to: .red) == true }
            let checked = try await harness.menu(of: noted, in: scene).items.first { $0.state == .on }
            #expect(checked.flatMap(CommentMenu.color(of:)) == .red)
            #expect(harness.window.firstResponder === card)
        }
    }

    /// Undoing and redoing a recolor redraws the underline on the page each time.
    @Test func undoAndRedoOfARecolorRedrawTheUnderline() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            let menu = try await harness.menu(of: noted, in: scene)
            try await harness.settle(drawing: .purple, under: letterRange)
            try perform(try #require(menu.items.first { CommentMenu.color(of: $0) == .green }))
            try await harness.expectDrawn(.green, not: .purple, under: letterRange)
            harness.focusPage(at: 0)
            try harness.undoOnThePage()
            try await harness.expectDrawn(.purple, not: .green, under: letterRange)
            try harness.undo.redo()
            try await harness.expectDrawn(.green, not: .purple, under: letterRange)
        }
    }

    /// A recolor from elsewhere than the menu (the page editor's own call) redraws the underline.
    @Test func aRecolorFromAnywhereRedrawsTheUnderline() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { harness in
            let letter = NSRange(location: 4, length: 6)
            let editor = try #require(harness.page.editor)
            try await harness.settle(drawing: .purple, under: letter)
            #expect(editor.recolor(noted, to: .blue))
            try await harness.expectDrawn(.blue, not: .purple, under: letter)
        }
    }

    /// A comment recolored while its paragraph is off screen shows the new color when it's
    /// scrolled into view.
    @Test func aRecolorOffScreenShowsWhenScrolledIn() async throws {
        let filler = Array(
            repeating: Paragraph([Run("The fog came in behind the radio and stayed until noon.")]), count: 40)
        try await withPage([scene("Long", filler + letterScene, .withTooEarly)]) { harness in
            let offset = (harness.storage.string as NSString).range(of: "letter").location
            let letter = NSRange(location: offset, length: 6)
            try #require(harness.storage.ranges(commentedBy: noted) == [letter], "precondition")
            harness.page.scrollRangeToVisible(NSRange(location: 0, length: 0))
            let layout = try #require(harness.page.textLayoutManager)
            func letterFrame() throws -> NSRect {
                let content = try #require(layout.textContentManager)
                let from = try #require(
                    content.location(layout.documentRange.location, offsetBy: letter.location))
                var frame = NSRect.zero
                layout.enumerateTextLayoutFragments(from: from, options: [.ensuresLayout]) {
                    frame = $0.layoutFragmentFrame
                    return false
                }
                return frame
            }
            try #require(
                !(try letterFrame()).intersects(harness.page.visibleRect), "precondition: off screen")
            #expect(harness.page.editor?.recolor(noted, to: .green) == true)
            harness.page.scrollRangeToVisible(letter)
            try #require(
                (try letterFrame()).intersects(harness.page.visibleRect), "precondition: scrolled in")
            try await harness.expectDrawn(.green, not: .purple, under: letter)
        }
    }

    /// Opening another scene ends a card's edit in the scene it was typed in, as one step.
    @Test func switchingScenesCommitsTheEditToItsScene() async throws {
        let second = scene("Two", [[Run("Elsewhere.")]])
        try await withPage([panelBook(), second]) { harness in
            harness.preferences.reveal(.comments)
            let first = try #require(harness.book.openScene)
            _ = try await harness.typeInCard(noted, " Then.")
            harness.book.select(second.id)
            #expect(harness.book.book.scene(first)?.comment(noted)?.text == "Too early? Then.")
            #expect(harness.book.pageUndo(for: first).undoActionName == CommentWording.editUndoName)
            #expect(!harness.book.pageUndo(for: second.id).canUndo)
        }
    }

    /// Showing another tab takes the card away mid-edit; the edit is kept as one step.
    @Test func leavingTheTabMidEditCommitsTheEdit() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            _ = try await harness.typeInCard(noted, " Hm.")
            harness.preferences.showRightPanelTab(.notes)
            await eventually { harness.cards.isEmpty }
            #expect(harness.text(of: noted) == "Too early? Hm.")
            #expect(harness.book.pageUndo(for: scene).undoActionName == CommentWording.editUndoName)
            harness.focusPage(at: 0)
            try harness.undoOnThePage()
            #expect(harness.text(of: noted) == "Too early?")
        }
    }

    /// A card that can't be edited any more mid-edit (a sheet opened over the panel, as for a
    /// read-only book) ends the edit, as the title field does: the card leaves the focus, the
    /// edit is kept as one step, and the card shows the model's text.
    @Test func aCardThatStopsBeingEditableEndsItsEdit() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            let card = try await harness.typeInCard(noted, " Now")
            harness.modes.mode = .scenes
            await eventually { !card.isEditable }
            #expect(harness.window.firstResponder !== card)
            #expect(harness.text(of: noted) == "Too early? Now")
            #expect(card.string == "Too early? Now")
            #expect(harness.book.pageUndo(for: scene).undoActionName == CommentWording.editUndoName)
            harness.modes.mode = .page
            await eventually { card.isEditable }
        }
    }

    /// Typing until the card no longer matches the search: the edit is still kept, as one step.
    @Test func typingACardOutOfTheSearchKeepsTheEdit() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            try WindowRenders.typeInSearch("early", in: harness.window)
            await eventually { harness.cards.map(\.comment) == [noted] }
            let card = try await harness.typeInCard(noted)
            card.selectAll(nil)
            card.insertText("Late?", replacementRange: card.selectedRange())
            await eventually { harness.card(noted) == nil }
            #expect(harness.text(of: noted) == "Late?")
            #expect(harness.book.pageUndo(for: scene).undoActionName == CommentWording.editUndoName)
        }
    }

    /// The ⋯ menu, as its control builds it: the seven colors in palette order, named, the
    /// comment's own checked, then Dismiss on ⌫; Re-anchor only on a detached card.
    @Test func theMenuListsTheColorsCheckedThenDismiss() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            let menu = try await harness.menu(of: noted, in: scene)
            #expect(menu.items.prefix(7).map(CommentMenu.color(of:)) == PaletteColor.allCases)
            #expect(
                menu.items.prefix(7).map {
                    $0.attributedTitle?.string.split(separator: " ").first.map(String.init)
                }
                    == PaletteColor.allCases.map(WindowWording.paletteName), "\"Red\", then its line")
            #expect(
                menu.items.prefix(7).map(\.state) == PaletteColor.allCases.map { $0 == .purple ? .on : .off })
            #expect(menu.items[7].isSeparatorItem)
            #expect(menu.items.dropFirst(8).map(\.title) == [CommentWording.dismiss])
            #expect(harness.page.editor?.comments.comment(in: scene) == noted, "opening it selects the card")

            harness.focusPage(at: 2)
            try #require(
                harness.window.firstResponder === harness.page, "precondition: the page has the focus")
            try #require(harness.page.selectedRange().length == 0, "precondition: no selection")
            let detached = try await harness.menu(of: gone, in: scene)
            #expect(
                detached.items.dropFirst(8).map(\.title) == [CommentWording.reanchor, CommentWording.dismiss])
            #expect(detached.items[8].isEnabled == false, "no selection on the page to re-anchor to")
        }
    }

    @Test func choosingAColorRecolorsAsOneUndoableStep() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            let menu = try await harness.menu(of: noted, in: scene)
            try perform(try #require(menu.items.first { CommentMenu.color(of: $0) == .red }))
            #expect(harness.book.book.scene(scene)?.comment(noted)?.color == .red)
            #expect(harness.preferences.lastCommentColor == .red, "the next comment's color")
            #expect(harness.book.pageUndo(for: scene).undoActionName == CommentWording.recolorUndoName)
            harness.focusPage(at: 0)
            try harness.undoOnThePage()
            #expect(harness.book.book.scene(scene)?.comment(noted)?.color == .purple)
            let again = try await harness.menu(of: noted, in: scene)
            #expect(again.items.first { $0.state == .on }.flatMap(CommentMenu.color(of:)) == .purple)
        }
    }

    /// ⌫ while the menu is open chooses Dismiss: the comment and its underline go; undo restores
    /// both.
    @Test func backspaceInTheMenuDismissesAndUndoRestores() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            let menu = try await harness.menu(of: noted, in: scene)
            let backspace = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: harness.window.windowNumber, context: nil, characters: "\u{7F}",
                    charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51))
            #expect(menu.performKeyEquivalent(with: backspace))
            #expect(harness.book.book.scene(scene)?.comments.map(\.id) == [early, gone])
            #expect(harness.storage.ranges(commentedBy: noted).isEmpty)
            await eventually { harness.card(noted) == nil }

            #expect(harness.book.pageUndo(for: scene).undoActionName == CommentWording.dismissUndoName)
            harness.focusPage(at: 0)
            try harness.undoOnThePage()
            #expect(harness.book.book.scene(scene)?.comments.map(\.id) == [noted, early, gone])
            #expect(harness.storage.ranges(commentedBy: noted) == [letterRange])
            await eventually { harness.card(noted) != nil && harness.page.commentPalette.covers(noted) }
        }
    }

    /// Dismissing the card being edited: its edit is committed first, in the same undo step, so
    /// one undo brings the comment back with the text it had before the edit, never the draft.
    @Test func dismissingTheCardBeingEditedKeepsTheEditAsAStep() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            _ = try await harness.typeInCard(noted, " Cut.")
            let menu = try await harness.menu(of: noted, in: scene)
            try perform(try #require(menu.items.first { $0.title == CommentWording.dismiss }))
            #expect(harness.book.book.scene(scene)?.comment(noted) == nil)
            #expect(harness.window.firstResponder === harness.page)
            try harness.undoOnThePage()
            #expect(harness.book.book.scene(scene)?.comment(noted) == tooEarly)
            #expect(harness.storage.ranges(commentedBy: noted) == [letterRange])
        }
    }

    /// As the ⋯ control opens the menu: a Dismiss chosen while it's open waits until it closes;
    /// a menu closed with nothing chosen does nothing.
    @Test func theMenusChoiceRunsOnlyOnceItHasClosed() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            harness.page.editor?.comments.select(noted, in: scene)
            await eventually { harness.menuControl(of: noted) != nil }
            let control = try #require(harness.menuControl(of: noted))
            let before = harness.book.book

            _ = try #require(control.openingMenu())
            control.runChosen()
            #expect(harness.book.book == before, "cancelled: nothing runs")
            #expect(!harness.book.pageUndo(for: scene).canUndo)

            let menu = try #require(control.openingMenu())
            try perform(try #require(menu.items.first { $0.title == CommentWording.dismiss }))
            #expect(harness.book.book.scene(scene)?.comment(noted) != nil, "not while it's open")
            control.runChosen()
            #expect(harness.book.book.scene(scene)?.comment(noted) == nil)
            #expect(harness.book.pageUndo(for: scene).undoActionName == CommentWording.dismissUndoName)
            control.runChosen()
            #expect(
                harness.book.pageUndo(for: scene).undoActionName == CommentWording.dismissUndoName, "once")
        }
    }

    /// A detached card's Re-anchor puts the comment on the page's selection.
    @Test func reanchorPutsADetachedCommentOnTheSelection() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            harness.window.makeFirstResponder(harness.page)
            harness.page.setSelectedRange(NSRange(location: 5, length: 4))
            await eventually { harness.formatting.commentablePage != nil }
            let menu = try await harness.menu(of: gone, in: scene)
            let reanchor = try #require(menu.items.first { $0.title == CommentWording.reanchor })
            #expect(reanchor.isEnabled)
            try perform(reanchor)
            #expect(harness.storage.ranges(commentedBy: gone) == [NSRange(location: 5, length: 4)])
            #expect(harness.book.pageUndo(for: scene).undoActionName == CommentWording.reanchorUndoName)
        }
    }

    /// The ⋯ control never takes the focus, so the page keeps its selection for Re-anchor.
    @Test func theMenuControlNeverTakesTheFocus() async throws {
        try await withPanel { harness in
            let scene = try #require(harness.book.openScene)
            _ = try await harness.menu(of: noted, in: scene)
            let control = try #require(harness.menuControl(of: noted))
            #expect(control.refusesFirstResponder)
            #expect(!control.canBecomeKeyView)
        }
    }

    /// The owner's rule: a new comment needs a selection. The + button, the floating button and
    /// Edit → New Comment all ask `EditorFormatting.commentablePage`; the floating button shows
    /// only while it answers, and a new comment's card takes the focus.
    @Test func aNewCommentNeedsASelectionAndOpensItsCard() async throws {
        try await withPanel { harness in
            harness.focusPage(at: 2)
            await eventually { harness.formatting.selection(in: .body) != nil }
            #expect(harness.formatting.commentablePage == nil, "a caret isn't enough")
            #expect(harness.page.commentButton.isHidden)

            harness.page.setSelectedRange(NSRange(location: 5, length: 4))
            #expect(harness.formatting.commentablePage === harness.page.editor)
            #expect(!harness.page.commentButton.isHidden)
            let band = try #require(harness.page.selectionBands.last)
            #expect(harness.page.commentButton.frame.minY >= band.maxY, "below the selection's end")

            harness.preferences.showRightPanelTab(.notes)
            CommentsTab.addComment(through: harness.formatting)
            #expect(harness.preferences.rightPanelTab == .comments, "the panel shows the new card")
            let id = try #require(harness.book.book.scene(harness.book.openScene)?.comments.last?.id)
            #expect(
                harness.storage.ranges(commentedBy: id) == [NSRange(location: 5, length: 4)], "the + made it")
            await eventually { harness.window.firstResponder === harness.card(id) }
            #expect(harness.formatting.commentablePage == nil, "the page has lost the focus")
            #expect(harness.page.commentButton.isHidden)
        }
    }

    /// The owner's bug B (#25): the floating button is a real button over the page. A press at
    /// its centre reaches it, not the text view; it shows the pointing hand; and its click
    /// comments the selection, which is still there.
    @Test func theFloatingButtonTakesItsClickBeforeTheText() async throws {
        try await withPanel { harness in
            let selection = NSRange(location: 5, length: 4)
            harness.window.makeFirstResponder(harness.page)
            harness.page.setSelectedRange(selection)
            await eventually { !harness.page.commentButton.isHidden }
            let button = harness.page.commentButton
            let centre = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            #expect(harness.window.contentView?.hitTest(centre) === button)
            let corner = button.convert(
                NSPoint(x: button.bounds.minX + 1, y: button.bounds.minY + 1), to: nil)
            #expect(
                harness.window.contentView?.hitTest(corner) === button, "its whole frame, not just the pill")
            #expect(button.acceptsFirstMouse(for: nil))
            #expect(button.refusesFirstResponder, "a click never takes the focus off the page")
            #expect(!button.canBecomeKeyView)
            #expect(
                button.trackingAreas.contains { $0.options.contains(.cursorUpdate) && $0.owner === button })

            #expect(harness.page.selectedRange() == selection, "precondition: the selection is there")
            button.performClick(nil)
            let id = try #require(harness.book.book.scene(harness.book.openScene)?.comments.last?.id)
            #expect(![noted, early, gone].contains(id))
            #expect(harness.storage.ranges(commentedBy: id) == [selection])
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
        book.book.scene(book.openScene)?.comment(comment)?.text
    }

    /// Gives `comment`'s card the focus, as a click on it does, with the caret at its end, and
    /// types `texts` there.
    func typeInCard(_ comment: CommentID, _ texts: String...) async throws -> CommentTextView {
        await eventually { card(comment) != nil }
        let card = try #require(card(comment))
        #expect(window.makeFirstResponder(card))
        card.setSelectedRange(NSRange(location: (card.string as NSString).length, length: 0))
        for text in texts { card.insertText(text, replacementRange: card.selectedRange()) }
        return card
    }

    /// Edit → Undo with the page focused, through the window's router as the toolbar does it.
    func undoOnThePage() throws {
        try #require(window.firstResponder === page, "precondition: the page has the focus")
        try undo.undo()
    }

    /// The color the page underlines `range` in, at the first level.
    func underlineColor(of range: NSRange) -> PaletteColor? {
        page.commentPalette.underlines(of: storage, depth: 5).first { $0.range == range && $0.level == 0 }?
            .color
    }

    /// Waits until the page has drawn `range`'s underline in `color` and its window has nothing
    /// left to draw, so a redraw seen after that was asked for, not left over from the window's
    /// first passes.
    func settle(drawing color: PaletteColor, under range: NSRange) async throws {
        await eventually {
            (try? lastDrawnColors(under: range)) == [color]
                && !subviewTree(of: window.contentView).contains(where: \.needsDisplay)
        }
    }

    /// The page shows `range`'s underline in `color`, and none in `old`.
    ///
    /// Two checks: what the paragraph last drew (`CommentUnderlineFragment.lastDrawn`), which is
    /// what the page shows, since TextKit 2 keeps each paragraph's drawing in a layer until it
    /// draws it again; and then the pixels that drawing gives. The pixels alone can't tell a
    /// stale paragraph: `shown()` renders the layers by drawing them afresh. So nothing may
    /// sample pixels between a change and the first check.
    func expectDrawn(
        _ color: PaletteColor, not old: PaletteColor, under range: NSRange,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        await eventually({ (try? lastDrawnColors(under: range)) == [color] }, sourceLocation: sourceLocation)
        #expect(
            try pagePixels(under: range, of: color) > 0, "in the new color", sourceLocation: sourceLocation)
        #expect(
            try pagePixels(under: range, of: old) == 0, "none left in the old", sourceLocation: sourceLocation
        )
    }

    /// The colors of the underlines the page last drew under `range`'s characters.
    func lastDrawnColors(under range: NSRange) throws -> [PaletteColor] {
        let layout = try #require(page.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let start = layout.documentRange.location
        let from = try #require(content.location(start, offsetBy: range.location))
        let to = try #require(content.location(from, offsetBy: range.length))
        var colors: [PaletteColor] = []
        layout.enumerateTextLayoutFragments(from: from, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(to) == .orderedAscending else { return false }
            let paragraph = content.offset(from: start, to: fragment.rangeInElement.location)
            let within = NSRange(location: range.location - paragraph, length: range.length)
            colors += ((fragment as? CommentUnderlineFragment)?.lastDrawn ?? [])
                .filter { ($0.range.intersection(within)?.length ?? 0) > 0 }.map(\.color)
            return true
        }
        return colors
    }

    /// The window drawn at 2x by rendering its layer-backed views' layers. That draws each layer
    /// afresh from the model, not the drawing it keeps (a probe showed a recolor in its pixels
    /// with no run-loop turn and no layer marked for display): it gives the colors a draw gives
    /// now, so it can't show a stale paragraph, and it refreshes `lastDrawn` as it draws.
    func shown() throws -> NSBitmapImageRep {
        let frameView = try #require(window.contentView?.superview)
        let size = frameView.bounds.size
        let rep = WindowRenders.blankBitmap(width: Int(size.width) * 2, height: Int(size.height) * 2)
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        context.scaleBy(x: 2, y: 2)
        // Each outermost layer-backed view's layer tree, where the view stands in the window.
        @MainActor func hasLayeredAncestor(_ view: NSView) -> Bool {
            var ancestor = view.superview
            while let current = ancestor, current !== frameView {
                if current.layer != nil { return true }
                ancestor = current.superview
            }
            return false
        }
        let layered = subviewTree(of: frameView).filter { $0.layer != nil && !$0.isHiddenOrHasHiddenAncestor }
        try #require(!layered.isEmpty, "precondition: some views draw into layers")
        for view in layered where !hasLayeredAncestor(view) {
            guard let layer = view.layer else { continue }
            let frame = view.convert(view.bounds, to: nil)
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.minY)
            if layer.isGeometryFlipped || view.isFlipped {
                context.translateBy(x: 0, y: frame.height)
                context.scaleBy(x: 1, y: -1)
            }
            layer.render(in: context)
            context.restoreGState()
        }
        return rep
    }

    /// The pixels of `shown` in `rect`, in window coordinates.
    func pixels(of shown: NSBitmapImageRep, in rect: NSRect) -> [NSColor] {
        let height = window.contentView?.superview?.bounds.height ?? 0
        var colors: [NSColor] = []
        for x in stride(from: Int(rect.minX * 2), to: Int(rect.maxX * 2), by: 1) {
            for y in stride(from: Int((height - rect.maxY) * 2), to: Int((height - rect.minY) * 2), by: 1) {
                if let color = shown.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { colors.append(color) }
            }
        }
        return colors
    }

    /// How many of the page's pixels under `range`'s text, its underlines' room included, are
    /// `color`, as the window shows them now.
    func pagePixels(under range: NSRange, of color: PaletteColor) throws -> Int {
        let layout = try #require(page.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let start = layout.documentRange.location
        let from = try #require(content.location(start, offsetBy: range.location))
        let to = try #require(content.location(from, offsetBy: range.length))
        let textRange = try #require(NSTextRange(location: from, end: to))
        var frames: [NSRect] = []
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            frames.append(frame)
            return true
        }
        let origin = page.textContainerOrigin
        let shown = try shown()
        return frames.reduce(0) { count, frame in
            let below = frame.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 1, dy: 0)
            let room = NSRect(x: below.minX, y: below.minY, width: below.width, height: below.height + 12)
            return count + pixels(of: shown, in: page.convert(room, to: nil)).count { $0.isClose(to: color) }
        }
    }

    /// The color the stripe at `card`'s left shows now. It renders the window, the page's
    /// paragraphs too (`shown()`), so it's sampled before a change or after its `lastDrawn` check,
    /// never between.
    func stripeColor(of card: CommentTextView) throws -> NSColor? {
        let text = card.convert(card.bounds, to: nil)
        return pixels(of: try shown(), in: NSRect(x: text.minX - 12, y: text.midY, width: 0.5, height: 0.5))
            .first
    }

    /// The menu `comment`'s ⋯ control opens, built by the control as a click builds it; the
    /// card is selected first, as the control shows only on a selected or hovered card.
    func menu(of comment: CommentID, in scene: SceneID) async throws -> NSMenu {
        page.editor?.comments.select(comment, in: scene)
        await eventually { menuControl(of: comment) != nil }
        let control = try #require(menuControl(of: comment))
        return try #require(control.makeMenu?() ?? nil)
    }

    func menuControl(of comment: CommentID) -> CommentMenuButton.Control? {
        subviewTree(of: window.contentView).compactMap { $0 as? CommentMenuButton.Control }.first {
            $0.comment == comment
        }
    }
}

extension NSColor {
    /// Whether this is `color`, give or take a little rounding.
    func isClose(to color: PaletteColor) -> Bool {
        guard let mine = usingColorSpace(.sRGB), let theirs = color.nsColor.usingColorSpace(.sRGB) else {
            return false
        }
        return abs(mine.redComponent - theirs.redComponent) < 0.06
            && abs(mine.greenComponent - theirs.greenComponent) < 0.06
            && abs(mine.blueComponent - theirs.blueComponent) < 0.06
    }
}
