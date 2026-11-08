import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// Focus mode in the app's own window, whose toolbar is the `Window` scene's: the hosted page
/// tests' windows have none.
extension BookStoreIntegrationTests {
    @MainActor
    private func openBook(at url: URL, in books: BookController) async throws -> (NSWindow, WindowChrome) {
        let window = try #require(books.mainWindow, "precondition: the app's main window")
        @MainActor func desk() -> DeskView? {
            subviewTree(of: window.contentView).lazy.compactMap { $0 as? DeskView }.first { $0.keys != nil }
        }
        await eventually { desk() != nil }
        await eventually { window.toolbar?.isVisible == true }
        let chrome = try #require(desk()?.keys?.chrome)
        try #require(window.toolbar?.isVisible == true, "precondition: the toolbar shows")
        return (window, chrome)
    }

    @Test func focusModeHidesTheAppWindowsToolbarAndLeavingBringsItBack() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            try #require(books.store.current?.addScene(after: nil) != nil, "a scene, so the page shows")
            let (window, chrome) = try await openBook(at: url, in: books)

            chrome.set(.on)
            await eventually { window.toolbar?.isVisible == false }
            #expect(window.toolbar?.isVisible == false, "focus mode hides the toolbar")
            chrome.set(.off)
            await eventually { window.toolbar?.isVisible == true }
            #expect(window.toolbar?.isVisible == true, "leaving shows it again")

            // The writer's own View → Hide Toolbar stays as they left it.
            window.toggleToolbarShown(nil)
            try #require(window.toolbar?.isVisible == false, "precondition: the writer hid the toolbar")
            chrome.set(.on)
            try await Task.sleep(for: .milliseconds(300))
            chrome.set(.off)
            try await Task.sleep(for: .milliseconds(300))
            #expect(
                window.toolbar?.isVisible == false, "leaving focus mode doesn't show a toolbar the writer hid"
            )
            window.toggleToolbarShown(nil)
            await eventually { window.toolbar?.isVisible == true }

            // Closing the book in focus mode; the book opens again out of it, toolbar and all.
            chrome.set(.on)
            await eventually { window.toolbar?.isVisible == false }
            #expect(await books.store.closeBook() == .left)
            #expect(await books.store.open(url) == .opened)
            let (_, reopened) = try await openBook(at: url, in: books)
            #expect(reopened !== chrome, "a new window state for the book opened again")
            #expect(reopened.focusMode == .off, "a book opens out of focus mode")
            #expect(window.toolbar?.isVisible == true)

            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}
