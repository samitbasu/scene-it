import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// After an event, AppKit updates the window, which is when the router looks at the focus
/// again; a test that moves the focus itself asks for that update.
@MainActor
private func focus(_ responder: NSResponder?, in page: PageHarness) {
    #expect(page.window.makeFirstResponder(responder))
    page.window.update()
}

/// The title's field editor, once the title has the focus.
@MainActor
private func titleEditor(in page: PageHarness) throws -> NSTextView {
    let editor = try #require(page.window.firstResponder as? NSTextView)
    #expect(editor.isFieldEditor, "precondition: the title is being edited")
    return editor
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct UndoRouterTests {
    @Test func eachFocusUndoesItsOwnHistory() async throws {
        let one = scene("One", [[Run("Start.")]])
        try await withPage([one]) { page in
            let router = try page.undo
            let pageUndo = page.book.pageUndo(for: one.id)

            focus(page.page, in: page)
            #expect(router.stack == .focusedText)
            #expect(router.manager === pageUndo, "the page: the scene's own history")

            focus(page.title, in: page)
            let editor = try titleEditor(in: page)
            #expect(router.stack == .focusedText)
            #expect(router.manager === editor.undoManager)
            #expect(
                router.manager === page.book.titleUndo(for: one.id),
                "the title: the scene title's own history")

            focus(nil, in: page)
            #expect(router.stack == UndoStack.none)
            #expect(router.state == .nothing, "with nothing focused there's nothing to undo")

            page.modes.mode = .scenes
            await eventually { page.window.firstResponder is UndoFocusView && router.mode == .scenes }
            #expect(router.stack == .structure)
            #expect(router.manager === page.book.structureUndo, "the Scenes sheet: the book's structure")
            let sheet = try #require(page.window.firstResponder as? UndoFocusView)
            #expect(sheet.undoManager === page.book.structureUndo, "AppKit asking the focused view agrees")

            page.modes.mode = .search
            await eventually { router.mode == .search }
            #expect(router.stack == UndoStack.none)
            #expect(router.manager == nil, "the Search sheet has nothing to undo")
            #expect(sheet.undoManager == nil)

            page.modes.mode = .page
            await eventually { router.mode == .page }
            focus(page.page, in: page)
            #expect(router.manager === pageUndo)
        }
    }

    @Test func theButtonsFollowTheRealHistories() async throws {
        let one = scene("One", [[Run("Start.")]])
        try await withPage([one]) { page in
            let router = try page.undo
            focus(page.page, in: page)
            page.focusPage(at: 6)
            #expect(router.state == .nothing, "nothing has been typed")

            page.page.insertText(" More.", replacementRange: page.page.selectedRange())
            page.page.breakUndoCoalescing()
            await eventually { router.state.undo != nil }
            #expect(router.state == UndoState(undo: "Undo Typing", redo: nil))

            router.undo()
            #expect(page.body() == [[Run("Start.")]])
            #expect(
                router.state == UndoState(undo: nil, redo: "Redo Typing"), "at once, without another event")

            router.redo()
            #expect(page.body() == [[Run("Start. More.")]])
            #expect(router.state == UndoState(undo: "Undo Typing", redo: nil))

            page.modes.mode = .scenes
            await eventually { router.stack == .structure }
            #expect(router.state == .nothing, "the structure has no history yet")
            page.modes.mode = .page
        }
    }

    /// Typing in one scene's title, then opening the next, keeps each title in its own scene,
    /// with its own history, and the title keeps the focus.
    @Test func eachScenesTitleKeepsWhatWasTypedInItAcrossNextScene() async throws {
        let one = scene("One", [[Run("First.")]])
        let two = scene("Two", [[Run("Second.")]])
        try await withPage([one, two]) { page in
            let router = try page.undo
            focus(page.title, in: page)
            let editor = try titleEditor(in: page)
            editor.setSelectedRange(NSRange(location: 3, length: 0))
            editor.insertText("X", replacementRange: editor.selectedRange())
            #expect(page.book.book.scene(one.id)?.title.text == "OneX")
            editor.breakUndoCoalescing()

            page.book.select(two.id)
            await eventually { page.storage.string == "Second." && page.title.currentEditor() != nil }
            #expect(page.title.stringValue == "Two")
            let next = try titleEditor(in: page)
            page.window.update()
            #expect(router.manager === page.book.titleUndo(for: two.id))
            #expect(router.state == .nothing, "One's title history is never offered on Two")

            next.insertText("Y", replacementRange: next.selectedRange())
            #expect(page.book.book.scene(two.id)?.title.text == "TwoY")
            #expect(page.book.book.scene(one.id)?.title.text == "OneX")
            next.breakUndoCoalescing()
            page.window.update()
            #expect(router.state.undo == "Undo Typing", "Two offers its own typing")
            router.undo()
            #expect(
                page.book.book.scene(two.id)?.title.text == "Two",
                "and undoing it changes Two's title only")
            #expect(page.book.book.scene(one.id)?.title.text == "OneX")
        }
    }

    @Test func aReadOnlyBookHasNothingToUndo() async throws {
        let one = scene("One", [[Run("First.")]])
        try await withPage([one], holdingTheLock: true) { page in
            #expect(!page.book.isEditable, "precondition: read-only")
            let router = try page.undo
            focus(page.page, in: page)
            #expect(router.state == .nothing)
            page.page.insertText("q", replacementRange: NSRange(location: 0, length: 0))
            page.window.update()
            #expect(router.state == .nothing)
            router.undo()
            #expect(page.body() == [[Run("First.")]])
        }
    }
}
