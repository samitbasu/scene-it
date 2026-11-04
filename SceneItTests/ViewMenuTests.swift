import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// The View menu's item titled `title`, after asking its menu to update as AppKit does when
/// the writer opens it or presses a shortcut (SwiftUI may replace the items then).
@MainActor
private func viewItem(_ title: String) -> NSMenuItem? {
    if let menu = menuItem(titled: title, in: NSApp.mainMenu)?.menu {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }
    return menuItem(titled: title, in: NSApp.mainMenu)
}

extension BookStoreIntegrationTests {
    @Test func theViewMenuZoomsAndStepsThroughTheStory() {
        let expected: [(String, String, NSEvent.ModifierFlags)] = [
            (WindowWording.zoomIn, "=", [.command]),
            (WindowWording.zoomOut, "-", [.command]),
            (WindowWording.actualSize, "0", [.command]),
            (WindowWording.fitWidth, "", []),
            (
                WindowWording.sceneStep(.previous), String(UnicodeScalar(NSUpArrowFunctionKey)!),
                [.command, .option]
            ),
            (
                WindowWording.sceneStep(.next), String(UnicodeScalar(NSDownArrowFunctionKey)!),
                [.command, .option]
            ),
        ]
        for (title, key, modifiers) in expected {
            let item = menuItem(titled: title, in: NSApp.mainMenu)
            #expect(item != nil, "\(title)")
            #expect(item?.keyEquivalent == key, "\(title)")
            if !key.isEmpty {
                #expect(
                    item?.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
                        == modifiers, "\(title)")
            }
        }
    }

    /// Edit → Undo and Redo are the app's, through the window's `UndoRouter`, rather than
    /// AppKit's `undo:` sent to whatever has the focus.
    @Test func theEditMenusUndoAndRedoGoThroughTheRouter() throws {
        let undo = try #require(menuItem(titled: WindowWording.undo, in: NSApp.mainMenu))
        let redo = try #require(menuItem(titled: WindowWording.redo, in: NSApp.mainMenu))
        #expect(undo.keyEquivalent == "z")
        #expect(
            undo.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [.command])
        #expect(redo.keyEquivalent == "z")
        #expect(
            redo.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [
                .command, .shift,
            ])
        for item in [undo, redo] {
            #expect(item.action != Selector(("undo:")) && item.action != Selector(("redo:")))
        }
    }

    @Test func zoomInOutAndActualSizeChangeTheAppWidePreference() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let preferences = books.preferences
            try #require(books.store.current == nil)
            try #require(preferences.zoom == .standard, "precondition: no other test left a zoom behind")
            await eventually { viewItem(WindowWording.zoomIn)?.isEnabled == false }

            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            await eventually { viewItem(WindowWording.zoomIn)?.isEnabled == true }

            try perform(try #require(viewItem(WindowWording.zoomIn)))
            #expect(preferences.zoom == Zoom(clamping: 1.1))
            try perform(try #require(viewItem(WindowWording.zoomOut)))
            try perform(try #require(viewItem(WindowWording.zoomOut)))
            #expect(preferences.zoom == Zoom(clamping: 0.9))
            #expect((preferences.storage as? TransientPreferenceStorage)?.values["zoom"] == "0.9")
            try perform(try #require(viewItem(WindowWording.actualSize)))
            #expect(preferences.zoom == .standard)
            #expect(book.status == .saved, "zoom isn't part of the book (ADR 0022)")

            preferences.setZoom(Zoom(clamping: 3))
            await eventually { viewItem(WindowWording.zoomIn)?.isEnabled == false }
            #expect(viewItem(WindowWording.zoomOut)?.isEnabled == true)
            try perform(try #require(viewItem(WindowWording.actualSize)))
            #expect(preferences.zoom == .standard)

            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }

    /// What was typed reaches the scene it was typed in, which is then saved, and the
    /// breadcrumb, rail and status move to the next scene.
    @Test func nextAndPreviousSceneOpenTheNeighbouringStoryScenes() async throws {
        let one = scene("One", [[Run("ab")]])
        let two = scene("Two", [[Run("Second.")]])
        try await withPage([one, two], books: .shared) { page in
            let next = WindowWording.sceneStep(.next)
            let previous = WindowWording.sceneStep(.previous)
            await eventually { viewItem(next)?.isEnabled == true }
            #expect(viewItem(previous)?.isEnabled == false, "the story's first scene")

            page.focusPage(at: 2)
            page.page.insertText("ni", replacementRange: page.page.selectedRange())

            try perform(try #require(viewItem(next)))
            #expect(page.book.openScene == two.id)
            await eventually { page.storage.string == "Second." }
            #expect(page.body(one.id) == [[Run("abni")]], "the typing is kept in its own scene")
            #expect(page.body(two.id) == [[Run("Second.")]], "the next scene is untouched")
            await eventually { page.book.status == .saved }
            #expect(try bookOnDisk(page.url).scenes.first?.body == [[Run("abni")]])

            let location = page.book.location
            #expect(WindowWording.breadcrumb(bookTitle: "Novel", location) == ["Novel", "2. Two"])
            #expect(CurrentSceneMark(location) == .badge("2"))
            #expect(WindowWording.currentSceneTooltip(location) == "Scene 2: Two")
            await eventually { viewItem(next)?.isEnabled == false }
            #expect(viewItem(previous)?.isEnabled == true)

            try perform(try #require(viewItem(previous)))
            #expect(page.book.openScene == one.id)
            await eventually { page.storage.string == "abni" }
        }
        expectNoQuestions()
    }
}
