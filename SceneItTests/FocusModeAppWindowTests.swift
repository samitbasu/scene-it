import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// Focus mode in the app's own window, whose toolbar is the `Window` scene's: the hosted page
/// tests' windows have none.
extension OneAtATime.BookStoreIntegrationTests {
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
            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }

    /// What can happen in focus mode, other than leaving it, leaves the toolbar hidden.
    @Test func theToolbarStaysHiddenThroughoutFocusMode() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            let first = try #require(book.addScene(after: nil))
            let second = try #require(book.addScene(after: first))
            book.select(first)
            let (window, chrome) = try await openBook(at: url, in: books)
            let desks = subviewTree(of: window.contentView).compactMap { $0 as? DeskView }
            let keys = try #require(desks.compactMap(\.keys).first)

            chrome.set(.on)
            await eventually { window.toolbar?.isVisible == false }
            // Every change to the toolbar's visibility, or to which toolbar the window has, from
            // here on: none may show one, even for a moment.
            let shown = ShownToolbars()
            let watching = [
                window.observe(\.toolbar, options: [.new]) { window, _ in
                    MainActor.assumeIsolated { shown.note(window.toolbar?.isVisible == true) }
                },
                try #require(window.toolbar).observe(\.isVisible, options: [.new]) { toolbar, _ in
                    MainActor.assumeIsolated { shown.note(toolbar.isVisible) }
                },
            ]
            defer { for observation in watching { observation.invalidate() } }
            @MainActor func stillHidden(_ what: String) async throws {
                try await Task.sleep(for: .milliseconds(300))
                #expect(shown.count == 0, "the toolbar never showed: \(what)")
                #expect(window.toolbar?.isVisible == false, "the toolbar is hidden: \(what)")
            }

            book.select(second)
            try await stillHidden("another scene opened")
            keys.mode.wrappedValue = .scenes
            try await stillHidden("a sheet opened")
            keys.mode.wrappedValue = .page
            try await stillHidden("the sheet closed")
            keys.filing.begin()
            await eventually { window.attachedSheet != nil }
            try await stillHidden("File a Copy's dialog up")
            keys.filing.cancel()
            await eventually { window.attachedSheet == nil }
            try await stillHidden("the dialog gone")
            #expect(chrome.focusMode == .on, "precondition: still in focus mode")

            chrome.set(.off)
            await eventually { window.toolbar?.isVisible == true }
            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }

    /// The owner's pick: View → Show/Hide Toolbar is disabled in focus mode.
    @Test func showAndHideToolbarIsDisabledInFocusMode() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            try #require(books.store.current?.addScene(after: nil) != nil, "a scene, so the page shows")
            let (_, chrome) = try await openBook(at: url, in: books)
            @MainActor func toolbarItem() -> NSMenuItem? {
                let titles = [ToolbarItemAction.show, .hide].map(WindowWording.toolbarItem)
                for title in titles {
                    if let menu = menuItem(titled: title, in: NSApp.mainMenu)?.menu {
                        menu.delegate?.menuNeedsUpdate?(menu)
                        menu.update()
                    }
                }
                return titles.lazy.compactMap { menuItem(titled: $0, in: NSApp.mainMenu) }.first
            }
            await eventually { toolbarItem()?.isEnabled == true }
            let item = try #require(toolbarItem(), "the View menu has the toolbar item")
            #expect(item.title == WindowWording.toolbarItem(.hide), "the toolbar shows, so the item hides it")
            #expect(item.keyEquivalent == "t")
            #expect(item.isEnabled, "outside focus mode the writer can hide the toolbar")

            chrome.set(.on)
            await eventually { toolbarItem()?.isEnabled == false }
            #expect(toolbarItem()?.isEnabled == false, "in focus mode it's disabled")
            chrome.set(.off)
            await eventually { toolbarItem()?.isEnabled == true }
            #expect(toolbarItem()?.isEnabled == true)
            #expect(await books.store.closeBook() == .left)
            await eventually { toolbarItem()?.isEnabled == false }
            #expect(toolbarItem()?.isEnabled == false, "on the start screen it's disabled")
            expectNoQuestions()
        }
    }

    /// Closing the book takes the window's Esc fallback out of its responder chain.
    @Test func closingTheBookLeavesNoEscapeResponderInTheChain() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            try #require(books.store.current?.addScene(after: nil) != nil, "a scene, so the page shows")
            let (window, _) = try await openBook(at: url, in: books)
            @MainActor func fallbacks() -> Int {
                var count = 0
                var responder: NSResponder? = window
                while let current = responder {
                    if current is WindowEscapeFallback.EscapeResponder { count += 1 }
                    responder = current.nextResponder
                }
                return count
            }
            await eventually { fallbacks() == 1 }
            #expect(fallbacks() == 1, "precondition: the open book's window has one")

            #expect(await books.store.closeBook() == .left)
            await eventually { fallbacks() == 0 }
            #expect(fallbacks() == 0, "none is left behind")
            expectNoQuestions()
        }
    }

    @Test func aToolbarTheWriterHidStaysHiddenAndCloseBookGivesItBack() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            try #require(books.store.current?.addScene(after: nil) != nil, "a scene, so the page shows")
            let (window, chrome) = try await openBook(at: url, in: books)

            // The writer's own View → Hide Toolbar stays as they left it.
            chrome.toggleToolbar()
            try #require(window.toolbar?.isVisible == false, "precondition: the writer hid the toolbar")
            chrome.set(.on)
            try await Task.sleep(for: .milliseconds(300))
            chrome.set(.off)
            try await Task.sleep(for: .milliseconds(300))
            #expect(
                window.toolbar?.isVisible == false, "leaving focus mode doesn't show a toolbar the writer hid"
            )
            chrome.toggleToolbar()
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

    /// In the app's own window, an Esc with no view holding the focus leaves focus mode as a key
    /// equivalent: past that, while the window is key, AppKit makes the key `cancelOperation:`,
    /// which SwiftUI's window answers before the window's Esc fallback can.
    @Test func escWithNoViewFocusedLeavesFocusModeInTheAppWindow() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            try #require(books.store.current?.addScene(after: nil) != nil, "a scene, so the page shows")
            let (window, chrome) = try await openBook(at: url, in: books)

            chrome.set(.on)
            await eventually { window.toolbar?.isVisible == false }
            #expect(window.makeFirstResponder(nil))
            try #require(window.firstResponder === window, "precondition: no view has the focus")
            #expect(window.performKeyEquivalent(with: try keyDown(.escape, in: window, .first)))
            #expect(chrome.focusMode == .off, "Esc leaves focus mode")
            await eventually { window.toolbar?.isVisible == true }

            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}

/// How many times a toolbar showed.
@MainActor
private final class ShownToolbars {
    private(set) var count = 0

    func note(_ visible: Bool) {
        if visible { count += 1 }
    }
}
