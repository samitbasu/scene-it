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
    if let menu = menuItem(titled: title, in: NSApp.mainMenu)?.menu {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }
    return menuItem(titled: title, in: NSApp.mainMenu)
}

/// The test host's main window: the app's own `Window` scene, showing `BookController.shared`.
@MainActor
private func mainWindow() -> NSWindow? {
    NSApp.windows.first {
        ($0.standardWindowButton(.closeButton)?.target as? CloseButtonQuits.Router)?.books
            === BookController.shared
    }
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

/// ADR 0038 through the app's own menus and window: one book per process; Close Book quits.
extension BookStoreIntegrationTests {
    @Test func newAndOpenAreOfferedOnlyInTheStartStateAndCloseBookOnlyWithABook() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start state")
            try #require(
                BookController.startStateClosing == .closeButtonOnly, "precondition: the current pick")
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

    /// Close Book's request reaches AppKit's quit from a run-loop source, never in the menu
    /// action's own turn, so `terminate`'s nested run loop can't block the quit path.
    @Test func closeBookAsksTheAppToQuitFromTheRunLoopAndLeavesTheBookToTheQuitPath() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            _ = books.takeRequests()
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            await eventually { fileItem(OneBookWording.closeBookMenuItem)?.isEnabled == true }

            try perform(try #require(fileItem(OneBookWording.closeBookMenuItem)))
            #expect(books.takeRequests() == [], "not carried out in the menu action's turn")

            #expect(await books.quitCarriedOut() == [quitCarriedOut])
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

            #expect(await books.quitCarriedOut() == [quitCarriedOut])
            #expect(window.isVisible, "the window stays until the quit goes through")
            #expect(books.store.current === book)
            #expect(await books.quitAndRelaunch() == .left)
            expectNoQuestions()
        }
    }

    /// ⌘W closes the book only from the book's window; any other key window just closes.
    @Test func closeBookClosesTheBookOnlyFromTheBooksWindow() async throws {
        let books = BookController.shared
        await eventually { mainWindow() != nil }
        let main = try #require(mainWindow())
        #expect(books.mainWindow === main, "the main window is the one whose close button is routed")
        let other = await hostOffscreen(
            Text("Report"), size: CGSize(width: 200, height: 100), until: { _ in true })
        defer { other.close() }
        try #require(other !== main, "precondition: another window")

        #expect(books.closeTarget(keyWindow: main) == .book)
        #expect(books.closeTarget(keyWindow: nil) == .book)
        #expect(books.closeTarget(keyWindow: other) == .window(other))
        #expect(
            BookController(role: .testHost).mainWindow == nil, "another controller's window isn't its own")
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
            #expect(await books.quitCarriedOut() == [quitCarriedOut])
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

    /// ADR 0018 then ADR 0038: when nothing opens in place of a changed book, the writer is told
    /// and the app quits, asked only once the store's operation is over.
    @Test func aLostBookQuitsTheAppAfterTheStoreIsDone() async throws {
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

            #expect(await books.quitCarriedOut() == [quitCarriedOut])
            guard case .ended = books.store.session else {
                Issue.record("the session is \(books.store.session)")
                return
            }
            #expect(
                prompts.notices.last?.message.hasSuffix(
                    "Scene It will quit now. Open it again to choose a book.") == true)
            let copy = folder.appending(path: "Novel (my edits).sceneit")
            #expect(books.store.recentBooks.first?.canonicalPath == copy.canonicalPath)
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
            let window = try #require(mainWindow())

            await books.openForwarded([url])

            #expect(books.takeRequests() == [.init(request: .bringForward(window), storeWasBusy: false)])
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

            #expect(books.takeRequests() == [.init(request: .bringForward(nil), storeWasBusy: false)])
            #expect(books.store.current?.layout.root.canonicalPath == url.canonicalPath)
            #expect(await books.store.prepareToQuit() == .left)
        }
    }
}
