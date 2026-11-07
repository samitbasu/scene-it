import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// The File menu's item titled `title`, after asking its menu to update as AppKit does when the
/// writer opens it or presses a shortcut.
@MainActor
private func fileItem(_ title: String) -> NSMenuItem? {
    if let menu = menuItem(titled: title, in: NSApp.mainMenu)?.menu {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }
    return menuItem(titled: title, in: NSApp.mainMenu)
}

/// The test host's main window, the app's own `Window` scene showing `BookController.shared`.
@MainActor
private func mainWindow() -> NSWindow? {
    NSApp.windows.first { $0.standardWindowButton(.closeButton)?.target is CloseButtonQuits.Router }
}

/// ADR 0038 through the app's own menus and window: one book per process; Close Book quits.
extension BookStoreIntegrationTests {
    @Test func newAndOpenAreOfferedOnlyInTheStartStateAndCloseBookOnlyWithABook() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start state")
            let closeTitle = OneBookWording.closeBookMenuItem
            let close = try #require(fileItem(closeTitle))
            #expect(close.keyEquivalent == "w")
            #expect(
                close.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [
                    .command
                ])
            await eventually {
                fileItem(StoreWording.newBookMenuItem)?.isEnabled == true
                    && fileItem(StoreWording.openBookMenuItem)?.isEnabled == true
                    && fileItem(closeTitle)?.isEnabled == false
            }

            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            await eventually {
                fileItem(StoreWording.newBookMenuItem)?.isEnabled == false
                    && fileItem(StoreWording.openBookMenuItem)?.isEnabled == false
                    && fileItem(closeTitle)?.isEnabled == true
            }

            #expect(await books.quitAndRelaunch() == .left)
            await eventually { fileItem(StoreWording.newBookMenuItem)?.isEnabled == true }
            expectNoQuestions()
        }
    }

    @Test func closeBookAsksTheAppToQuitAndLeavesTheBookToTheQuitPath() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            _ = books.takeRequests()
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            await eventually { fileItem(OneBookWording.closeBookMenuItem)?.isEnabled == true }

            try perform(try #require(fileItem(OneBookWording.closeBookMenuItem)))

            #expect(books.takeRequests() == [.quit])
            #expect(books.store.current === book, "only the quit path closes the book")
            #expect(book.isEditable)
            #expect(await books.quitAndRelaunch() == .left)
            expectNoQuestions()
        }
    }

    @Test func theWindowsCloseButtonAsksTheAppToQuitAndTheWindowStays() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            _ = books.takeRequests()
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            await eventually { mainWindow() != nil }
            let window = try #require(mainWindow())
            let button = try #require(window.standardWindowButton(.closeButton))
            try #require(
                button.target is CloseButtonQuits.Router, "precondition: routed, so the click can't close it")

            button.performClick(nil)

            #expect(books.takeRequests() == [.quit])
            #expect(window.isVisible, "the window stays until the quit goes through")
            #expect(books.store.current === book)
            #expect(await books.quitAndRelaunch() == .left)
            expectNoQuestions()
        }
    }

    /// The quit path's Cancel (here the unfiled-copy question, whose default is Cancel) keeps
    /// the book open and editable, in the window.
    @Test func cancelInTheQuitPromptKeepsTheBookOpen() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let headless = try #require(books.prompts as? HeadlessPrompts)
            _ = books.takeRequests()
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            var draft = FilingDraft(today: CalendarDay(.now, in: .current))
            draft.note = "Before the ending"
            book.filingDraft = draft

            books.closeBook()
            #expect(books.takeRequests() == [.quit])
            #expect(await books.store.prepareToQuit() == .stayed)

            #expect(headless.takeTitles() == ["Quit without filing the copy?"])
            #expect(books.store.current === book)
            #expect(book.isEditable)
            await eventually { fileItem(OneBookWording.closeBookMenuItem)?.isEnabled == true }
            book.filingDraft = nil
            #expect(await books.quitAndRelaunch() == .left)
            expectNoQuestions()
        }
    }

    /// Through AppKit's open request, as a book forwarded by a second launch (ADR 0020) arrives.
    @Test func aForwardedOtherBookIsRefusedWithAnAlertAndTheWindowComesForward() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let headless = try #require(books.prompts as? HeadlessPrompts)
            _ = books.takeRequests()
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            let other = folder.appending(path: "Other Book.sceneit", directoryHint: .isDirectory)
            _ = try BookPackage.create(at: other, title: "Other Book")
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            let delegate = try #require(NSApp.delegate)

            delegate.application?(NSApp, open: [other])
            await eventually { !headless.titles.isEmpty }

            #expect(books.takeRequests() == [.bringWindowForward])
            #expect(headless.takeTitles() == [OneBookWording.refusal(of: [other], whileOpen: url).title])
            #expect(books.store.current === book)
            guard case .editing = try BookPackage.open(at: other) else {
                Issue.record("the other book was locked")
                return
            }
            #expect(await books.quitAndRelaunch() == .left)
            expectNoQuestions()
        }
    }

    @Test func theForwardedOpenBookJustComesForward() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            _ = books.takeRequests()
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)

            await books.openForwarded([url])

            #expect(books.takeRequests() == [.bringWindowForward])
            #expect(books.store.current === book)
            #expect(await books.quitAndRelaunch() == .left)
            expectNoQuestions()
        }
    }

    @Test func aForwardedBookOpensInTheStartState() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            _ = try BookPackage.create(at: url, title: "My Novel")

            await books.openForwarded([url])

            #expect(books.takeRequests() == [.bringWindowForward])
            #expect(books.store.current?.layout.root.canonicalPath == url.canonicalPath)
            #expect(await books.store.prepareToQuit() == .left)
        }
    }
}
