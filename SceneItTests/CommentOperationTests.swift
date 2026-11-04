import AppKit
import SceneItCore
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

    /// With nothing selected, the word at the caret (PLAN §8.1); then typing at either edge of it
    /// stays out of the comment.
    @Test func withNoSelectionTheWordAtTheCaretIsCommentedAndTypingBesideItIsNot() async throws {
        try await withPage([scene("One", Self.plain)]) { harness in
            let editor = try #require(harness.page.editor)
            harness.focusPage(at: Self.letter.upperBound)
            let id = try #require(editor.newComment())
            #expect(harness.body().first?.runs[1] == Run("letter", color: .red, comments: [id]))
            #expect(harness.page.selectedRange() == NSRange(location: Self.letter.upperBound, length: 0))
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

    @Test func nothingToCommentMakesNoComment() async throws {
        try await withPage([scene("One", [[Run("The letter.")], [], [Run("Dawn.")]])]) { harness in
            let editor = try #require(harness.page.editor)
            harness.focusPage(at: 12)
            #expect(editor.newComment() == nil, "an empty line has no word")
            harness.page.setSelectedRange(NSRange(location: 11, length: 2))
            #expect(editor.newComment() == nil, "line breaks carry no comment")
            #expect(harness.book.book.scenes.first?.comments.isEmpty == true)
            #expect(harness.page.undoManager?.canUndo == false)
        }
    }

    // MARK: Typing and pasting never extend a comment (PLAN §8.1)

    @Test func pastingAtEitherEdgeOfACommentNeverExtendsItAndUndoRestoresIt() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { harness in
            try #require(harness.storage.ranges(commentedBy: noted) == [Self.letter], "precondition")
            try await PageHarness.withPasteboard { pasteboard in
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

            #expect(await asAnEvent(undo) { editor.dismiss(noted) })
            #expect(harness.book.book.scene(scene)?.comments.isEmpty == true)
            undo.undo()
            #expect(harness.book.book.scene(scene)?.comments == [tooEarly])
            #expect(harness.body() == letterScene.map(\.uncommented))
            #expect(harness.pageMirrorsModel)
        }
    }

    // MARK: Refusals

    @Test func aReadOnlyBookRefusesEveryCommentOperation() async throws {
        try await withPage([scene("Held", letterScene, .withTooEarly)], holdingTheLock: true) { harness in
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

@MainActor
private final class ResultBox<T> {
    var value: T?
}

extension BookStoreIntegrationTests {
    /// PLAN §11: Edit → New Comment, Cmd+Option+M.
    @Test func theEditMenuHasNewComment() throws {
        let item = try #require(menuItem(titled: CommentWording.newComment, in: NSApp.mainMenu))
        #expect(item.keyEquivalent == "m")
        #expect(
            item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == [
                .command, .option,
            ])
    }
}
