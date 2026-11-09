import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// Comment operations (PLAN §8.1) through the page's own editor and the real `OpenBook`: each is
/// one change on the page's undo, keeps the page, its underlines and the selected comment in
/// step, saves, and never reaches the notes.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CommentOperationTests {
    private static let plain: [Paragraph] = [
        [Run("The "), Run("letter", color: .red), Run(" waited.")], [Run("Dawn.")],
    ]
    private static let letter = NSRange(location: 4, length: 6)

    // MARK: Creating

    @Test func aNewCommentCoversTheSelectionInTheLastColorAndIsSelected() async throws {
        try await withPage([scene("One", Self.plain)]) { harness in
            harness.preferences.rememberCommentColor(.blue)
            let editor = try #require(harness.page.editor)
            let scene = try #require(harness.book.openScene)
            harness.window.makeFirstResponder(harness.page)
            harness.page.setSelectedRange(Self.letter)
            #expect(
                (harness.storage.string as NSString).substring(with: Self.letter) == "letter", "precondition")

            let undo = try #require(harness.page.undoManager)
            let id = try #require(await asAnEvent(undo) { editor.newComment() })
            let comment = try #require(harness.book.book.scene(scene)?.comments.first)
            #expect(harness.book.book.scene(scene)?.comments.count == 1)
            #expect(comment.id == id && comment.color == .blue && comment.text.isEmpty)
            #expect(
                harness.body().first == [
                    Run("The "), Run("letter", color: .red, comments: [id]), Run(" waited."),
                ])
            #expect(harness.pageMirrorsModel)
            #expect(harness.page.selectedRange() == Self.letter, "the selection stays")
            #expect(editor.comments.comment(in: scene) == id)
            await eventually { harness.page.commentPalette.covers(id) }
            #expect(undo === harness.book.pageUndo(for: scene))
            #expect(undo.undoActionName == CommentWording.newComment)

            undo.undo()
            #expect(harness.body() == Self.plain)
            #expect(harness.book.book.scene(scene)?.comments.isEmpty == true)
            await eventually { !harness.page.commentPalette.covers(id) }
            #expect(editor.comments.comment(in: scene) == nil, "the selection goes with the comment")
            #expect(harness.pageMirrorsModel)

            undo.redo()
            #expect(harness.book.book.scene(scene)?.comments == [comment])
            #expect(Paragraph.commentIDs(in: harness.body()) == [id])
            await eventually { harness.page.commentPalette.covers(id) }
            #expect(harness.pageMirrorsModel)

            await eventually { harness.book.status == .saved }
            #expect(try bookOnDisk(harness.url) == harness.book.book)
        }
    }

    /// Typing at either edge of a comment just made on a selection stays out of it.
    @Test func typingBesideANewCommentIsNotCommented() async throws {
        try await withPage([scene("One", Self.plain)]) { harness in
            let editor = try #require(harness.page.editor)
            harness.window.makeFirstResponder(harness.page)
            harness.page.setSelectedRange(Self.letter)
            let id = try #require(editor.newComment())
            #expect(harness.body().first?.runs[1] == Run("letter", color: .red, comments: [id]))
            harness.focusPage(at: Self.letter.upperBound)
            harness.page.insertText("s", replacementRange: harness.page.selectedRange())
            harness.focusPage(at: Self.letter.location)
            harness.page.insertText("a ", replacementRange: harness.page.selectedRange())
            #expect(
                harness.body().first == [
                    Run("The a "), Run("letter", color: .red, comments: [id]), Run("s", color: .red),
                    Run(" waited."),
                ])
            #expect(harness.pageMirrorsModel)
        }
    }

    /// ADR 0037: with no selection, or one of only line breaks, there's nothing to comment.
    @Test func nothingToCommentMakesNoComment() async throws {
        try await withPage([scene("One", [[Run("The letter.")], [], [Run("Dawn.")]])]) { harness in
            let editor = try #require(harness.page.editor)
            harness.focusPage(at: 6)
            #expect(editor.newComment() == nil, "a caret inside a word")
            harness.page.setSelectedRange(NSRange(location: 11, length: 2))
            #expect(editor.newComment() == nil, "line breaks carry no comment")
            #expect(harness.book.book.scenes.first?.comments.isEmpty == true)
            harness.page.setSelectedRange(NSRange(location: 3, length: 1))
            #expect(editor.newComment() != nil, "a selection of only a space may be commented")
            #expect(harness.book.book.scenes.first?.comments.count == 1)
        }
    }

    /// An undo manager doesn't retain its targets (#119): a new comment's undo crashed once the
    /// object it was registered against was freed. Undo and redo again and again, freeing and
    /// reusing memory in between, so a freed target would be called.
    @Test func aNewCommentUndoesAndRedoesLongAfterItWasMade() async throws {
        try await withPage([scene("One", Self.plain)]) { harness in
            let editor = try #require(harness.page.editor)
            let undo = try #require(harness.page.undoManager)
            let scene = try #require(harness.book.openScene)
            harness.window.makeFirstResponder(harness.page)
            harness.page.setSelectedRange(Self.letter)
            let id = try #require(await asAnEvent(undo) { editor.newComment() })
            let made = try #require(harness.book.book.scene(scene)?.comments.first)
            for round in 0..<20 {
                churnTheHeap()
                undo.undo()
                #expect(harness.body() == Self.plain, "round \(round)")
                #expect(harness.book.book.scene(scene)?.comments.isEmpty == true, "round \(round)")
                churnTheHeap()
                undo.redo()
                #expect(harness.book.book.scene(scene)?.comments == [made], "round \(round)")
                #expect(Paragraph.commentIDs(in: harness.body()) == [id], "round \(round)")
            }
            #expect(harness.pageMirrorsModel)
        }
    }

    // MARK: Typing and pasting never extend a comment (PLAN §8.1)

    @Test func pastingAtEitherEdgeOfACommentNeverExtendsItAndUndoRestoresIt() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { harness in
            try #require(harness.storage.ranges(commentedBy: noted) == [Self.letter], "precondition")
            try await PageHarness.withPasteboard { pasteboard in
                // A page clip brings its own runs, so it would extend the comment only if the paste
                // took the typing attributes instead; the plain text below takes them, which is
                // what stripping `.comments` from them guards.
                harness.window.makeFirstResponder(harness.page)
                harness.page.setSelectedRange(NSRange(location: 10, length: 7))
                #expect(
                    harness.page.writeSelection(to: pasteboard, types: harness.page.writablePasteboardTypes))
                #expect(pasteboard.types?.contains(.pageClip) == true)
                let undo = try #require(harness.page.undoManager)

                for edge in [Self.letter.upperBound, Self.letter.location] {
                    harness.focusPage(at: edge)
                    #expect(harness.page.readSelection(from: pasteboard))
                    harness.page.breakUndoCoalescing()
                    #expect(
                        harness.storage.ranges(commentedBy: noted).map(\.length) == [6], "clip at \(edge)")
                    undo.undo()
                    #expect(harness.body() == letterScene)
                }

                pasteboard.clearContents()
                pasteboard.setString("ink", forType: .string)
                for edge in [Self.letter.upperBound, Self.letter.location] {
                    harness.focusPage(at: edge)
                    #expect(harness.page.readSelection(from: pasteboard))
                    harness.page.breakUndoCoalescing()
                    #expect(
                        harness.storage.ranges(commentedBy: noted).map(\.length) == [6], "text at \(edge)")
                    #expect(Paragraph.commentIDs(in: harness.body()) == [noted])
                    undo.undo()
                    #expect(harness.body() == letterScene)
                }
                #expect(harness.pageMirrorsModel)
            }
        }
    }

    @Test func undoingTypingAtAnEdgeLeavesTheCommentAsItWas() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { harness in
            for edge in [Self.letter.upperBound, Self.letter.location] {
                harness.focusPage(at: edge)
                harness.page.insertText("xy", replacementRange: harness.page.selectedRange())
                harness.page.breakUndoCoalescing()
                #expect(harness.storage.ranges(commentedBy: noted).map(\.length) == [6], "typed at \(edge)")
                try #require(harness.page.undoManager).undo()
                #expect(harness.body() == letterScene)
                #expect(harness.storage.ranges(commentedBy: noted) == [Self.letter])
            }
            #expect(harness.pageMirrorsModel)
        }
    }

    // MARK: Editing, recoloring

    @Test func editingAndRecoloringAreUndoableAndTheUnderlinesFollow() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { harness in
            let editor = try #require(harness.page.editor)
            let scene = try #require(harness.book.openScene)
            let undo = try #require(harness.page.undoManager)
            harness.focusPage(at: 0)
            #expect(await asAnEvent(undo) { editor.setText("Why \u{201C}now\u{201D}?", ofComment: noted) })
            #expect(harness.book.book.scene(scene)?.comments.first?.text == "Why \"now\"?")
            #expect(undo.undoActionName == CommentWording.editUndoName)

            #expect(await asAnEvent(undo) { editor.recolor(noted, to: .green) })
            #expect(harness.preferences.lastCommentColor == .green, "the next comment's color")
            #expect(undo.undoActionName == CommentWording.recolorUndoName)
            let shown = {
                harness.page.commentPalette == CommentPalette(harness.book.book.scene(scene)?.comments ?? [])
            }
            await eventually(shown)
            #expect(harness.book.book.scene(scene)?.comments.first?.color == .green)

            undo.undo()
            #expect(harness.book.book.scene(scene)?.comments.first?.color == .purple)
            await eventually(shown)
            undo.undo()
            #expect(harness.book.book.scene(scene)?.comments == [tooEarly])
            #expect(harness.preferences.lastCommentColor == .green, "undo leaves the chosen color")
            undo.redo()
            undo.redo()
            #expect(harness.book.book.scene(scene)?.comments.first?.text == "Why \"now\"?")
            #expect(harness.book.book.scene(scene)?.comments.first?.color == .green)
            await eventually(shown)
            #expect(harness.body() == letterScene, "the text is untouched")

            await eventually { harness.book.status == .saved }
            #expect(try bookOnDisk(harness.url) == harness.book.book)
        }
    }

    // MARK: Dismissing and re-anchoring

    /// PLAN §8.1: dismissing removes the comment, card and underline; undoing it restores both.
    @Test func dismissingTakesTheCommentOffItsTextAndUndoRestoresBoth() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { harness in
            let editor = try #require(harness.page.editor)
            let scene = try #require(harness.book.openScene)
            let undo = try #require(harness.page.undoManager)
            editor.comments.select(noted, in: scene)
            await eventually { harness.page.commentPalette.covers(noted) }

            #expect(await asAnEvent(undo) { editor.dismiss(noted) })
            #expect(harness.book.book.scene(scene)?.comments.isEmpty == true)
            #expect(harness.body() == letterScene.map(\.uncommented))
            #expect(editor.comments.comment(in: scene) == nil)
            #expect(undo.undoActionName == CommentWording.dismissUndoName)
            #expect(harness.pageMirrorsModel)
            await eventually { !harness.page.commentPalette.covers(noted) }

            undo.undo()
            #expect(harness.book.book.scene(scene)?.comments == [tooEarly])
            #expect(harness.body() == letterScene)
            #expect(harness.pageMirrorsModel)
            await eventually { harness.page.commentPalette.covers(noted) }

            undo.redo()
            #expect(harness.book.book.scene(scene)?.comments.isEmpty == true)
            #expect(harness.body() == letterScene.map(\.uncommented))
            await eventually { harness.book.status == .saved }
            #expect(try bookOnDisk(harness.url) == harness.book.book)
        }
    }

    @Test func aDetachedCommentIsReanchoredOrDismissed() async throws {
        let detached = scene("One", letterScene.map(\.uncommented), .withTooEarly)
        try await withPage([detached]) { harness in
            let editor = try #require(harness.page.editor)
            let scene = try #require(harness.book.openScene)
            let undo = try #require(harness.page.undoManager)
            try #require(harness.book.book.scene(scene)?.isDetached(noted) == true, "precondition")
            harness.window.makeFirstResponder(harness.page)
            harness.page.setSelectedRange(NSRange(location: 0, length: 3))

            #expect(await asAnEvent(undo) { editor.reanchor(noted) })
            #expect(harness.body().first?.runs.first == Run("The", comments: [noted]))
            #expect(editor.comments.comment(in: scene) == noted)
            #expect(undo.undoActionName == CommentWording.reanchorUndoName)
            #expect(!editor.reanchor(noted), "only a detached comment")
            harness.page.breakUndoCoalescing()
            undo.undo()
            #expect(harness.book.book.scene(scene)?.isDetached(noted) == true)
            #expect(harness.book.book.scene(scene)?.comments == [tooEarly], "it's kept, detached")
            #expect(undo.redoActionName == CommentWording.reanchorUndoName)
            undo.redo()
            #expect(harness.body().first?.runs.first == Run("The", comments: [noted]))
            #expect(harness.pageMirrorsModel)
            undo.undo()
            try #require(harness.book.book.scene(scene)?.isDetached(noted) == true, "precondition: detached")

            #expect(await asAnEvent(undo) { editor.dismiss(noted) })
            #expect(harness.book.book.scene(scene)?.comments.isEmpty == true)
            #expect(undo.undoActionName == CommentWording.dismissUndoName)
            undo.undo()
            #expect(harness.book.book.scene(scene)?.comments == [tooEarly])
            #expect(harness.body() == letterScene.map(\.uncommented))
            #expect(harness.pageMirrorsModel)
            #expect(undo.redoActionName == CommentWording.dismissUndoName)
            undo.redo()
            #expect(harness.book.book.scene(scene)?.comments.isEmpty == true)
            #expect(harness.body() == letterScene.map(\.uncommented))
            #expect(harness.pageMirrorsModel)
        }
    }

    // MARK: Refusals

    @Test func aReadOnlyBookRefusesEveryCommentOperation() async throws {
        try await withPage([scene("Held", letterScene, .withTooEarly)], lock: .heldElsewhere) { harness in
            let editor = try #require(harness.page.editor)
            let before = harness.book.book
            harness.window.makeFirstResponder(harness.page)
            harness.page.setSelectedRange(Self.letter)
            #expect(editor.newComment() == nil)
            #expect(!editor.setText("No", ofComment: noted))
            #expect(!editor.recolor(noted, to: .green))
            #expect(harness.preferences.lastCommentColor == .purple, "a refused recolor chooses nothing")
            #expect(!editor.dismiss(noted))
            #expect(!editor.reanchor(noted))
            #expect(harness.book.book == before)
            #expect(harness.page.undoManager?.canUndo != true)
        }
    }

    /// Comments are on the manuscript only (ADR 0035): the notes' editor makes none, and a
    /// comment made on the page leaves the notes as they were.
    @Test func noCommentEverReachesTheNotes() async throws {
        var commented = scene("One", Self.plain)
        commented.notes = [[Run("The letter again.")]]
        try await withPage([commented]) { harness in
            let notes = try await harness.showNotes()
            let notesEditor = try #require(notes.editor)
            harness.focusNotes(notes, at: 0)
            notes.setSelectedRange(NSRange(location: 4, length: 6))
            #expect(notesEditor.newComment() == nil)
            #expect(!notesEditor.reanchor(noted))
            #expect(harness.book.book.scenes.first?.comments.isEmpty == true)

            harness.window.makeFirstResponder(harness.page)
            harness.page.setSelectedRange(Self.letter)
            let pageEditor = try #require(harness.page.editor)
            let id = try #require(pageEditor.newComment())
            #expect(harness.notes() == [[Run("The letter again.")]])
            #expect(notes.textStorage?.attribute(.comments, at: 5, effectiveRange: nil) == nil)
            #expect(harness.book.notesUndo(for: commented.id).canUndo == false)
            #expect(Paragraph.commentIDs(in: harness.body()) == [id])
            await eventually { harness.book.status == .saved }
            #expect(try bookOnDisk(harness.url).scenes.first?.notes == [[Run("The letter again.")]])
        }
    }
}

/// `body`'s result, run as one event of its own (`inAnEvent`), so its undo group is closed
/// and named once it returns, as before the writer's next event.
@MainActor
private func asAnEvent<T>(_ undo: UndoManager, _ body: @escaping @MainActor () -> T) async -> T {
    let box = ResultBox<T>()
    await inAnEvent(undo) { box.value = body() }
    return box.value!
}

/// Allocates and frees many small objects, so memory freed earlier is reused and overwritten.
private func churnTheHeap() {
    autoreleasepool {
        var objects: [NSObject] = (0..<20_000).map { _ in NSObject() }
        objects += (0..<5_000).map { NSString(format: "churn %d", $0) }
        objects.removeAll()
    }
}

@MainActor
private final class ResultBox<T> {
    var value: T?
}

extension CommentOperationTests {
    /// Each comment action ends the page's typing, so typing either side of it undoes as a step
    /// of its own, in order.
    @Test func typingBetweenCommentActionsUndoesInStepsOfItsOwn() async throws {
        var commented = scene("One", letterScene, .withTooEarly)
        let loose = Comment(
            id: CommentID(rawValue: "01JC4K0000000000000000LOSE"), color: .pink, text: "Cut?",
            created: tooEarly.created)
        commented.comments.append(loose)
        try await withPage([commented]) { harness in
            let editor = try #require(harness.page.editor)
            let undo = try #require(harness.page.undoManager)
            let scene = commented.id
            @MainActor func state() -> Step {
                let now = harness.book.book.scene(scene)
                return Step(
                    text: harness.body().first?.text, color: now?.comments.first?.color,
                    note: now?.comments.first?.text, comments: now?.comments.map(\.id))
            }
            @MainActor func type(_ text: String) async {
                await inAnEvent(undo) {
                    harness.page.insertText(text, replacementRange: harness.page.selectedRange())
                }
            }
            harness.focusPage(at: 18)
            await type("A")
            #expect(await asAnEvent(undo) { editor.recolor(noted, to: .green) })
            await type("B")
            #expect(await asAnEvent(undo) { editor.setText("Why?", ofComment: noted) })
            await type("C")
            #expect(await asAnEvent(undo) { editor.dismiss(loose.id) })
            #expect(state().comments == [noted], "precondition: dismissed")
            let both = [noted, loose.id]
            let steps = [
                Step(text: "The letter waited.ABC", color: .green, note: "Why?", comments: both),
                Step(text: "The letter waited.AB", color: .green, note: "Why?", comments: both),
                Step(text: "The letter waited.AB", color: .green, note: "Too early?", comments: both),
                Step(text: "The letter waited.A", color: .green, note: "Too early?", comments: both),
                Step(text: "The letter waited.A", color: .purple, note: "Too early?", comments: both),
                Step(text: "The letter waited.", color: .purple, note: "Too early?", comments: both),
            ]
            for (index, expected) in steps.enumerated() {
                try #require(undo.canUndo, "undo \(index + 1)")
                undo.undo()
                #expect(state() == expected, "after undo \(index + 1)")
            }
            #expect(harness.body() == letterScene)
            #expect(harness.pageMirrorsModel)
        }
    }

    private struct Step: Equatable {
        let text: String?
        let color: PaletteColor?
        let note: String?
        let comments: [CommentID]?
    }
}

/// Edit → New Comment, after asking its menu to update as AppKit does when the writer opens it
/// or presses a shortcut.
@MainActor
func newCommentItem() -> NSMenuItem? {
    if let menu = menuItem(titled: CommentWording.newComment, in: NSApp.mainMenu)?.menu {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }
    return menuItem(titled: CommentWording.newComment, in: NSApp.mainMenu)
}

/// Cmd+Shift+M, made in this process for our own menu, as a key press would reach it.
@MainActor
private func commandShiftM(in window: NSWindow) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "M",
            charactersIgnoringModifiers: "m",
            isARepeat: false, keyCode: 46))
}

extension BookStoreIntegrationTests {
    /// PLAN §11's New Comment, on ADR 0037's Cmd+Shift+M, which no other item has.
    @Test func theEditMenuHasNewCommentOnCommandShiftMAlone() throws {
        let item = try #require(newCommentItem())
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        #expect(item.keyEquivalent.lowercased() == "m")
        #expect(item.keyEquivalentModifierMask.intersection(modifiers) == [.command, .shift])
        @MainActor func items(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
        }
        let sharing = items(NSApp.mainMenu).filter {
            $0.keyEquivalent.lowercased() == "m"
                && $0.keyEquivalentModifierMask.intersection(modifiers) == [.command, .shift]
        }
        #expect(sharing.map(\.title) == [CommentWording.newComment])
    }

    /// Enabled with the page focused, editable and holding a selection; disabled with only a
    /// caret or only line breaks selected, in the notes, the title field and under a sheet, where
    /// Cmd+Shift+M reaches no other item and changes nothing.
    @Test func newCommentIsEnabledOnlyOnAnEditablePageWithTheFocus() async throws {
        var commented = scene("One", [[Run("The letter waited.")], [], [Run("Dawn.")]])
        commented.notes = [[Run("Notes.")]]
        try await withPage([commented], books: .shared) { harness in
            let tab = harness.preferences.rightPanelTab
            defer { harness.preferences.showRightPanelTab(tab) }
            harness.focusPage(at: 6)
            await eventually { harness.formatting.selection(in: .body) != nil }
            #expect(newCommentItem()?.isEnabled == false, "no selection: nothing to comment")
            harness.page.setSelectedRange(NSRange(location: 4, length: 6))
            await eventually { newCommentItem()?.isEnabled == true }
            try perform(try #require(newCommentItem()))
            let made = try #require(harness.book.book.scene(commented.id)?.comments.first)
            #expect(harness.body().first?.runs[1] == Run("letter", comments: [made.id]), "the menu commented")

            @MainActor func pressingItChangesNothing() throws {
                let before = harness.book.book
                _ = NSApp.mainMenu?.performKeyEquivalent(with: try commandShiftM(in: harness.window))
                #expect(harness.book.book == before)
            }
            harness.page.setSelectedRange(NSRange(location: 18, length: 2))
            await eventually { newCommentItem()?.isEnabled == false }
            try pressingItChangesNothing()

            let notes = try await harness.showNotes()
            harness.focusNotes(notes, at: 0)
            notes.setSelectedRange(NSRange(location: 0, length: 5))
            await eventually { newCommentItem()?.isEnabled == false }
            try pressingItChangesNothing()

            harness.window.makeFirstResponder(harness.title)
            await eventually { newCommentItem()?.isEnabled == false }
            try pressingItChangesNothing()

            harness.window.makeFirstResponder(harness.page)
            harness.page.setSelectedRange(NSRange(location: 0, length: 3))
            await eventually { newCommentItem()?.isEnabled == true }
            harness.modes.mode = .scenes
            await eventually { newCommentItem()?.isEnabled == false }
            try pressingItChangesNothing()
            harness.modes.mode = .page
            await eventually { harness.book.status == .saved }
        }
    }

    @Test func newCommentIsDisabledInAReadOnlyBook() async throws {
        try await withPage([scene("Held", [[Run("Kept.")]])], lock: .heldElsewhere, books: .shared) {
            harness in
            harness.window.makeFirstResponder(harness.page)
            harness.page.setSelectedRange(NSRange(location: 0, length: 4))
            try #require(
                harness.window.firstResponder === harness.page, "precondition: the page has the focus")
            try #require(!harness.page.isEditable, "precondition: read-only")
            await eventually { newCommentItem()?.isEnabled == false }
            let before = harness.book.book
            _ = NSApp.mainMenu?.performKeyEquivalent(with: try commandShiftM(in: harness.window))
            #expect(harness.book.book == before)
        }
        let headless = try #require(BookController.shared.prompts as? HeadlessPrompts)
        #expect(headless.takeTitles() == [ReadOnlyWording.readOnlyTitle], "the only question: read-only")
    }
}
