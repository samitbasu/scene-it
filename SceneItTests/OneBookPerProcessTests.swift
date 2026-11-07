import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// The File menu's item titled `title`, after asking its menu to update as AppKit does when the
/// writer opens it or presses a shortcut.
@MainActor
private func fileItem(_ title: String) -> NSMenuItem? {
    if let menu = menuItem(titled: StoreWording.saveMenuItem, in: NSApp.mainMenu)?.menu {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }
    return menuItem(titled: title, in: NSApp.mainMenu)
}

/// The test host's main window: the app's own `Window` scene, showing `BookController.shared`.
@MainActor
private func mainWindow() -> NSWindow? {
    BookController.shared.mainWindow
}

/// The quit AppKit would have been asked for, carried out a run-loop turn after the request,
/// with the store idle.
private let quitCarriedOut = RecordedRequests.Carried(request: .quit, storeWasBusy: false)

extension BookController {
    /// Waits for the run-loop source that carries out a quit.
    @MainActor
    fileprivate func quitCarriedOut() async -> [RecordedRequests.Carried] {
        await eventually { recorded?.carried.contains { $0.request == .quit } == true }
        return takeRequests()
    }
}

/// Chooses Open Other Version when a save finds another program's version, after making the
/// original unreadable, so nothing can be opened in its place (ADR 0038's lost book).
private final class LosingPrompts: StorePrompts {
    let original: URL
    private(set) var notices: [Notice] = []

    init(original: URL) {
        self.original = original
    }

    func ask<Choice>(_ alert: WriterAlert<Choice>) async -> Choice {
        guard let other = alert.choices.first(where: { ($0 as? ExternalChangeChoice) == .openOtherVersion })
        else { return alert.choices[0] }
        let book = original.appending(path: "book.md")
        try? FileManager.default.removeItem(at: book)
        try? FileManager.default.createDirectory(at: book, withIntermediateDirectories: false)
        return other
    }

    func tell(_ notice: Notice) async {
        notices.append(notice)
    }
}

/// ADR 0038 through the app's own menus and window: one book at a time; Close Book returns to
/// the start screen; closing the start screen quits.
extension BookStoreIntegrationTests {
    @Test func newAndOpenAreOfferedOnlyOnTheStartScreen() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            try #require(BookController.startScreenCommandW == .quits, "precondition: the current pick")
            let startClose = OneBookWording.startScreenCloseMenuItem
            await eventually {
                fileItem(StoreWording.newBookMenuItem)?.isEnabled == true
                    && fileItem(StoreWording.openBookMenuItem)?.isEnabled == true
                    && fileItem(startClose)?.isEnabled == true
            }
            let close = try #require(fileItem(startClose))
            #expect(close.keyEquivalent == "w")
            #expect(
                close.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [
                    .command
                ])

            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            await eventually {
                fileItem(StoreWording.newBookMenuItem)?.isEnabled == false
                    && fileItem(StoreWording.openBookMenuItem)?.isEnabled == false
                    && fileItem(OneBookWording.closeBookMenuItem)?.isEnabled == true
            }

            #expect(await books.store.closeBook() == .left)
            await eventually { fileItem(StoreWording.newBookMenuItem)?.isEnabled == true }
            expectNoQuestions()
        }
    }

    @Test func closeBookSavesAndReturnsToTheStartScreenWithoutQuitting() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            _ = books.takeRequests()
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            let scene = try #require(book.addScene(after: nil))
            book.replaceBody(of: scene, with: [[Run("Typed just before closing")]])
            await eventually { fileItem(OneBookWording.closeBookMenuItem)?.isEnabled == true }

            try perform(try #require(fileItem(OneBookWording.closeBookMenuItem)))

            await eventually { books.store.isChoosing }
            #expect(book.status == .closed)
            #expect(try bookOnDisk(url) == book.book)
            await eventually { fileItem(StoreWording.newBookMenuItem)?.isEnabled == true }
            #expect(books.takeRequests() == [], "nothing quit")
            expectNoQuestions()
        }
    }

    @Test func theCloseButtonClosesTheBookAndTheWindowStaysForTheStartScreen() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            _ = books.takeRequests()
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            await eventually { mainWindow() != nil }
            let window = try #require(mainWindow())
            let button = try #require(window.standardWindowButton(.closeButton))
            try #require(
                button.target is MainWindowCloseButton.Router,
                "precondition: routed, so the click can't close the window")

            button.performClick(nil)

            await eventually { books.store.isChoosing }
            #expect(window.isVisible)
            #expect(books.takeRequests() == [], "nothing quit")
            expectNoQuestions()
        }
    }

    /// The start screen's close button quits, through AppKit's quit, started from a run-loop
    /// source and never in the click's own turn, so `terminate`'s nested run loop can't block
    /// the quit path.
    @Test func theStartScreensCloseButtonQuitsFromTheRunLoop() async throws {
        let books = BookController.shared
        _ = books.takeRequests()
        try #require(books.store.isChoosing, "precondition: the start screen")
        await eventually { mainWindow() != nil }
        let button = try #require(mainWindow()?.standardWindowButton(.closeButton))

        button.performClick(nil)
        #expect(books.takeRequests() == [], "not carried out in the click's turn")

        #expect(await books.quitCarriedOut() == [quitCarriedOut])
        #expect(mainWindow()?.isVisible == true, "the window stays until the quit goes through")
    }

    @Test func commandWOnTheStartScreenQuitsAsTheSwitchSays() async throws {
        let books = BookController.shared
        _ = books.takeRequests()
        try #require(books.store.isChoosing, "precondition: the start screen")
        try #require(BookController.startScreenCommandW == .quits, "precondition: the current pick")
        let item = try #require(fileItem(OneBookWording.startScreenCloseMenuItem))

        try perform(item)

        #expect(await books.quitCarriedOut() == [quitCarriedOut])
        expectNoQuestions()
    }

    @Test func theMainWindowsCloseButtonIsRoutedToTheApp() async throws {
        await eventually { NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("main") == true } }
        let window = try #require(
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true },
            "precondition: the app's own main window scene")
        await eventually { window.standardWindowButton(.closeButton)?.target is MainWindowCloseButton.Router }
        let button = try #require(window.standardWindowButton(.closeButton))
        let router = try #require(button.target as? MainWindowCloseButton.Router)
        #expect(router.books === BookController.shared)
        #expect(button.action == NSSelectorFromString("closeClicked:"))
        #expect(BookController.shared.mainWindow === window)
    }

    /// The Dock icon brings back a main window that isn't on screen, and leaves a visible one to
    /// AppKit. (A controller and window of the test's own, so the app's window stays up: a
    /// SwiftUI app with only a `Window` scene quits once no window is left.)
    @Test func reopeningFromTheDockBringsBackTheMainWindow() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let size = WindowMetrics.defaultSize
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: MainWindow(books: books))
            window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
            window.orderFront(nil)
            defer { window.close() }
            await eventually { books.mainWindow != nil }
            try #require(
                books.mainWindow === window && window.isVisible, "precondition: its window, on screen")
            #expect(books.reopenMainWindow(), "a visible window is AppKit's to handle")
            #expect(books.takeRequests() == [])

            window.orderOut(nil)
            try #require(!window.isVisible, "precondition: off screen")
            #expect(!books.reopenMainWindow())
            #expect(books.takeRequests() == [.init(request: .bringForward(window), storeWasBusy: false)])
            #expect(await books.store.closeBook() == .left)
        }
    }

    /// ⌘W with another window key closes that window, through its own close, and leaves the
    /// book alone.
    @Test func closeBookWithAnotherWindowKeyClosesThatWindow() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            let other = NSWindow(
                contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 100),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            other.orderFront(nil)
            defer { other.close() }
            try #require(other.isVisible, "precondition: on screen")

            await books.closeFromMenu(keyWindow: other)

            #expect(!other.isVisible, "closed")
            #expect(books.store.current === book, "the book stays open")
            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }

    /// The whole close decision, for each state and source.
    @Test func closeActionsFollowTheStateAndTheSource() async throws {
        try await withTemporaryFolder { folder in
            try #require(BookController.startScreenCommandW == .quits, "precondition: the current pick")
            let books = BookController(role: .testHost)
            let other = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            #expect(books.closeAction(from: .closeButton) == .quit)
            #expect(books.closeAction(from: .menu(keyWindow: nil)) == .quit)
            #expect(books.closeAction(from: .menu(keyWindow: other)) == .closeWindow(other))
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            #expect(books.closeAction(from: .closeButton) == .closeBook)
            #expect(books.closeAction(from: .menu(keyWindow: nil)) == .closeBook)
            #expect(books.closeAction(from: .menu(keyWindow: other)) == .closeWindow(other))
            #expect(await books.store.closeBook() == .left)
        }
    }

    /// ⌘W acts on the main window only from it or a window it owns; any other key window just
    /// closes.
    @Test func commandWActsOnTheMainWindowOnlyFromIt() async throws {
        let books = BookController.shared
        await eventually { mainWindow() != nil }
        let main = try #require(mainWindow())
        #expect(books.mainWindow === main, "the main window is the one whose close button is routed")
        let other = await hostOffscreen(
            Text("Report"), size: CGSize(width: 200, height: 100), until: { _ in true })
        defer { other.close() }
        let child = await hostOffscreen(
            Text("Child"), size: CGSize(width: 200, height: 100), until: { _ in true })
        defer { child.close() }
        main.addChildWindow(child, ordered: .above)
        defer { main.removeChildWindow(child) }
        try #require(other !== main && child.parent === main, "precondition: another window and a child")

        #expect(books.closeTarget(keyWindow: main) == .mainWindow)
        #expect(books.closeTarget(keyWindow: child) == .mainWindow)
        #expect(books.closeTarget(keyWindow: nil) == .mainWindow)
        #expect(books.closeTarget(keyWindow: other) == .window(other))
        #expect(
            BookController(role: .testHost).mainWindow == nil, "another controller's window isn't its own")
    }

    /// The close prompt's Cancel (here the unfiled-copy question, whose default is Cancel)
    /// keeps the book open and editable.
    @Test func cancelInTheClosePromptKeepsTheBookOpen() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let headless = try #require(books.prompts as? HeadlessPrompts)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            var draft = FilingDraft(today: CalendarDay(.now, in: .current))
            draft.note = "Before the ending"
            book.filingDraft = draft
            await eventually { fileItem(OneBookWording.closeBookMenuItem)?.isEnabled == true }

            try perform(try #require(fileItem(OneBookWording.closeBookMenuItem)))
            await eventually { !headless.titles.isEmpty }

            #expect(headless.takeTitles() == ["Close without filing the copy?"])
            #expect(books.store.current === book)
            #expect(book.isEditable)
            book.filingDraft = nil
            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }

    /// ADR 0018 then ADR 0038: when nothing opens in place of a changed book, the writer is
    /// told, and the start screen shows with their version first in Recent Books.
    @Test func aLostBookReturnsToTheStartScreen() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            let prompts = LosingPrompts(original: url)
            let books = BookController(role: .testHost, prompts: prompts)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            let scene = try #require(book.addScene(after: nil))
            await eventually { book.status == .saved }
            var theirs = try bookOnDisk(url)
            theirs.title = "Their version"
            try BookFormat.serialize(theirs).write(to: url.appending(path: "book.md"), options: .atomic)

            book.setTitle(of: scene, to: "My version")
            books.store.saveNow()

            await eventually { books.store.isChoosing }
            let copy = folder.appending(path: "Novel (my edits).sceneit")
            #expect(
                prompts.notices.last?.message.hasSuffix("“Novel (my edits)” is first in Recent Books.")
                    == true)
            #expect(books.store.recentBooks.first?.canonicalPath == copy.canonicalPath)
            #expect(books.takeRequests() == [], "nothing quit")
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
            let window = try #require(mainWindow(), "precondition: the main window, to come forward")
            let delegate = try #require(NSApp.delegate)

            delegate.application?(NSApp, open: [other])
            await eventually { !headless.titles.isEmpty }

            #expect(books.takeRequests() == [.init(request: .bringForward(window), storeWasBusy: false)])
            #expect(headless.takeTitles() == [OneBookWording.refusal(of: [other], whileOpen: url).title])
            #expect(books.store.current === book)
            guard case .editing = try BookPackage.open(at: other) else {
                Issue.record("the other book was locked")
                return
            }
            #expect(await books.store.closeBook() == .left)
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
            let window = try #require(mainWindow())

            await books.openForwarded([url])

            #expect(books.takeRequests() == [.init(request: .bringForward(window), storeWasBusy: false)])
            #expect(books.store.current === book)
            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }

    @Test func aForwardedBookOpensFromTheStartScreen() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            _ = try BookPackage.create(at: url, title: "My Novel")

            await books.openForwarded([url])

            #expect(books.takeRequests() == [.init(request: .bringForward(nil), storeWasBusy: false)])
            #expect(books.store.current?.layout.root.canonicalPath == url.canonicalPath)
            #expect(await books.store.closeBook() == .left)
        }
    }
}
