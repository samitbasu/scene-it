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

/// Runs `body` in the first main-actor turn after `store` reaches the start screen: before any
/// task the change's own turn then waits on (the close releasing the book) can resume, since
/// the main actor runs its jobs in the order they arrive.
@MainActor
private func whenTheStartScreenShows(_ store: AppBookStore, _ body: @escaping @MainActor () -> Void) {
    withObservationTracking {
        _ = store.session
    } onChange: {
        Task { @MainActor in
            if store.isChoosing { body() } else { whenTheStartScreenShows(store, body) }
        }
    }
}

extension BookController {
    /// Runs `body`; if it throws with a quit still under way, plays the quit path to its end as
    /// AppKit would, so a test that fails part-way can't leave the shared controller quitting.
    @MainActor
    fileprivate func settlingQuits(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            if isQuitUnderWay { _ = await settleQuit() }
            throw error
        }
    }

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

/// Holds each question until `answer`, so a test can act while the writer is being asked.
private final class HoldingPrompts: StorePrompts {
    private(set) var titles: [String] = []
    private var held: CheckedContinuation<Void, Never>?
    private var next: (any Hashable & Sendable)?

    func ask<Choice>(_ alert: WriterAlert<Choice>) async -> Choice {
        titles.append(alert.title)
        await withCheckedContinuation { held = $0 }
        defer { next = nil }
        return (next as? Choice) ?? alert.choices[0]
    }

    func tell(_ notice: Notice) async {
        titles.append(notice.title)
    }

    func answer(_ choice: any Hashable & Sendable) {
        next = choice
        held?.resume()
        held = nil
    }
}

/// ADR 0038 through the app's own menus and window: one book at a time; Close Book returns to
/// the start screen; the window's red close button quits (#130).
extension OneAtATime.BookStoreIntegrationTests {
    @Test func newAndOpenAreOfferedOnlyOnTheStartScreenAndSaveOnlyWithABook() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let startClose = OneBookWording.startScreenCloseMenuItem
            await eventually {
                fileItem(StoreWording.newBookMenuItem)?.isEnabled == true
                    && fileItem(StoreWording.openBookMenuItem)?.isEnabled == true
                    && fileItem(startClose)?.isEnabled == true
                    && fileItem(StoreWording.saveMenuItem)?.isEnabled == false
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
                    && fileItem(StoreWording.saveMenuItem)?.isEnabled == true
            }

            #expect(await books.store.closeBook() == .left)
            await eventually {
                fileItem(StoreWording.newBookMenuItem)?.isEnabled == true
                    && fileItem(StoreWording.saveMenuItem)?.isEnabled == false
            }
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

    /// #130: the red button with a book open quits, through Quit's own path: one request,
    /// carried out a run-loop turn after the click, however many clicks; the book stays open
    /// until that path runs, then is saved and released there.
    @Test func theCloseButtonWithABookOpenQuitsThroughTheQuitPath() async throws {
        let books = BookController.shared
        try await withTemporaryFolder { folder in
            try await books.settlingQuits {
                _ = books.takeRequests()
                let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
                #expect(await books.store.create(at: url) == .created)
                let book = try #require(books.store.current)
                let scene = try #require(book.addScene(after: nil))
                await eventually { book.status == .saved }
                book.replaceBody(of: scene, with: [[Run("Typed just before quitting")]])
                await eventually { mainWindow() != nil }
                let window = try #require(mainWindow())
                let button = try #require(window.standardWindowButton(.closeButton))
                try #require(
                    button.target is MainWindowCloseButton.Router,
                    "precondition: routed, so the click can't close the window")

                button.performClick(nil)
                button.performClick(nil)
                #expect(books.takeRequests() == [], "not carried out in the click's turn")

                #expect(await books.quitCarriedOut() == [quitCarriedOut])
                #expect(books.store.current === book, "the book stays open until the quit path runs")
                #expect(window.isVisible)
                #expect(books.closeAction(from: .menu(keyWindow: nil)) == .nothing, "⌘W waits for the quit")

                // Autosave waits 2 s after the last edit (AutosavePolicy.idleDelay); the app's
                // controller has no clock to hold, so the precondition is checked here, just
                // before the quit path runs, with no suspension in between.
                try #require(book.status == .unsaved, "precondition: autosave hasn't saved the edit")
                try #require(try bookOnDisk(url) != book.book, "precondition: the edit isn't on disk yet")
                #expect(
                    await books.settleQuit() == .left, "the quit path, as applicationShouldTerminate runs it")
                #expect(book.status == .closed)
                #expect(try bookOnDisk(url) == book.book, "saved first")
                try await Task.sleep(for: .milliseconds(100))
                #expect(books.takeRequests() == [], "the second click asked for nothing")
                expectNoQuestions()
            }
        }
    }

    /// Quit's Cancel, after the red button, keeps the book open and editable, and leaves the
    /// next press to be decided afresh.
    @Test func cancelInTheQuitPromptAfterTheCloseButtonKeepsTheBookOpen() async throws {
        let books = BookController.shared
        try await withTemporaryFolder { folder in
            try await books.settlingQuits {
                let headless = try #require(books.prompts as? HeadlessPrompts)
                _ = books.takeRequests()
                let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
                #expect(await books.store.create(at: url) == .created)
                let book = try #require(books.store.current)
                var draft = FilingDraft(today: CalendarDay(.now, in: .current))
                draft.note = "Before the ending"
                book.filingDraft = draft

                #expect(books.press(.closeButton) == nil, "a quit has nothing to wait for here")
                #expect(await books.quitCarriedOut() == [quitCarriedOut])
                #expect(await books.settleQuit() == .stayed)

                #expect(headless.takeTitles() == ["Quit without filing the copy?"])
                #expect(books.store.current === book)
                #expect(book.isEditable)
                #expect(books.closeAction(from: .closeButton) == .quit, "ready for the next press")
                #expect(books.closeAction(from: .menu(keyWindow: nil)) == .closeBook)
                book.filingDraft = nil
                #expect(await books.store.closeBook() == .left)
                expectNoQuestions()
            }
        }
    }

    /// A close held at its question, then a quit queued behind it (⌘Q while Close Book asks):
    /// the close's Cancel doesn't end the quit. A red press during the quit does nothing, and
    /// once the quit is cancelled too, presses are decided afresh.
    @Test func aCancelledCloseLeavesAQuitQueuedBehindItUnderWay() async throws {
        try await withTemporaryFolder { folder in
            let prompts = HoldingPrompts()
            let books = BookController(role: .testHost, prompts: prompts)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            var draft = FilingDraft(today: CalendarDay(.now, in: .current))
            draft.note = "Before the ending"
            books.store.current?.filingDraft = draft

            let closing = try #require(books.press(.menu(keyWindow: nil)))
            await eventually { prompts.titles == ["Close without filing the copy?"] }
            let quitting = Task { await books.settleQuit() }
            await eventually { books.isQuitUnderWay }
            prompts.answer(UnfiledDraftChoice.cancel)
            await closing.value

            #expect(books.isQuitUnderWay, "the close cleared only its own")
            #expect(books.closeAction(from: .closeButton) == .nothing)
            #expect(books.press(.closeButton) == nil)
            await eventually { prompts.titles.count == 2 }
            #expect(prompts.titles.last == "Quit without filing the copy?")
            prompts.answer(UnfiledDraftChoice.cancel)
            #expect(await quitting.value == .stayed)

            #expect(!books.isQuitUnderWay)
            #expect(books.closeAction(from: .closeButton) == .quit)
            try await Task.sleep(for: .milliseconds(100))
            #expect(books.takeRequests() == [], "the red press during the quit asked for nothing")
            books.store.current?.filingDraft = nil
            #expect(await books.store.closeBook() == .left)
        }
    }

    /// A click decided as a quit just before Quit reached `applicationShouldTerminate` leaves a
    /// quit waiting for its run-loop source; the quit path drops it as it ends, so it can't
    /// start a second quit after the writer's Cancel.
    @Test func aQuitQueuedBeforeTheQuitPathIsDroppedWhenItEnds() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            var draft = FilingDraft(today: CalendarDay(.now, in: .current))
            draft.note = "Before the ending"
            books.store.current?.filingDraft = draft

            #expect(books.press(.closeButton) == nil)
            #expect(await books.settleQuit() == .stayed, "Cancel, the headless default")

            try await Task.sleep(for: .milliseconds(100))
            #expect(books.takeRequests() == [], "the queued quit never ran")
            #expect(books.closeAction(from: .closeButton) == .quit)
            books.store.current?.filingDraft = nil
            #expect(await books.store.closeBook() == .left)
        }
    }

    /// If AppKit's `terminate` returns without the quit path running (AppKit never asked
    /// `applicationShouldTerminate`), the press's backstop ends the quit, so the red button and
    /// ⌘W work again.
    @Test func aQuitWhoseTerminateReturnsIsOverAndPressesWorkAgain() async throws {
        let books = BookController(role: .testHost, recordedTerminate: .over)
        #expect(books.press(.closeButton) == nil)
        #expect(books.isQuitUnderWay, "precondition: the quit is under way")
        #expect(books.closeAction(from: .closeButton) == .nothing)

        await eventually { !books.isQuitUnderWay }
        #expect(books.takeRequests() == [.init(request: .quit, storeWasBusy: false)])
        #expect(books.closeAction(from: .closeButton) == .quit, "pressing works again")
        #expect(books.closeAction(from: .menu(keyWindow: nil)) == .quit)
    }

    /// The same backstop, for `AppRequests` alone: it runs once a `terminate` that returns is
    /// done, and not for the test host's recorder, whose quit the test settles itself.
    @Test func aQuitThatTerminateReturnsFromIsOver() async throws {
        let requests = AppRequests(carryOut: { _ in .over })
        var over = 0
        requests.quit { over += 1 }
        #expect(over == 0, "not in the sender's turn")
        await eventually { over == 1 }

        let recorded = AppRequests(carryOut: { _ in .leftToTheTest })
        var stillPending = 0
        recorded.quit { stillPending += 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(stillPending == 0, "the test host's quit is the test's to settle")
    }

    /// The start screen's close button quits, through AppKit's quit, started from a run-loop
    /// source and never in the click's own turn, so `terminate`'s nested run loop can't block
    /// the quit path.
    @Test func theStartScreensCloseButtonQuitsFromTheRunLoop() async throws {
        let books = BookController.shared
        try await books.settlingQuits {
            _ = books.takeRequests()
            try #require(books.store.isChoosing, "precondition: the start screen")
            await eventually { mainWindow() != nil }
            let button = try #require(mainWindow()?.standardWindowButton(.closeButton))

            button.performClick(nil)
            #expect(books.takeRequests() == [], "not carried out in the click's turn")

            #expect(await books.quitCarriedOut() == [quitCarriedOut])
            #expect(mainWindow()?.isVisible == true, "the window stays until the quit goes through")
            #expect(await books.settleQuit() == .left)
        }
    }

    @Test func commandWOnTheStartScreenQuits() async throws {
        let books = BookController.shared
        try await books.settlingQuits {
            _ = books.takeRequests()
            try #require(books.store.isChoosing, "precondition: the start screen")
            let item = try #require(fileItem(OneBookWording.startScreenCloseMenuItem))

            try perform(item)

            #expect(await books.quitCarriedOut() == [quitCarriedOut])
            #expect(await books.settleQuit() == .left)
            expectNoQuestions()
        }
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

    /// Owner's pick (M2): a close is decided when it's pressed. Two ⌘W presses in quick
    /// succession with a book open (a key repeat) close the book once and never quit.
    @Test func twoQuickCloseBookPressesCloseTheBookOnceAndDontQuit() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            _ = books.takeRequests()
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)

            let first = books.press(.menu(keyWindow: nil))
            let second = books.press(.menu(keyWindow: nil))
            await first?.value
            await second?.value

            #expect(books.store.isChoosing, "the start screen shows")
            #expect(book.status == .closed)
            try await Task.sleep(for: .milliseconds(100))
            #expect(books.takeRequests() == [], "nothing quit")
            expectNoQuestions()
        }
    }

    /// While Close Book is still asking, the store is `closing`, and another press is ignored.
    /// Once the start screen shows, a fresh press quits.
    @Test func aPressWhileClosingIsIgnoredAndOneAfterwardsQuits() async throws {
        try await withTemporaryFolder { folder in
            let prompts = HoldingPrompts()
            let books = BookController(role: .testHost, prompts: prompts)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            var draft = FilingDraft(today: CalendarDay(.now, in: .current))
            draft.note = "Before the ending"
            books.store.current?.filingDraft = draft

            let closing = books.press(.menu(keyWindow: nil))
            await eventually { prompts.titles == ["Close without filing the copy?"] }
            guard case .closing = books.store.session else {
                Issue.record("precondition: a close in flight")
                return
            }
            #expect(books.closeAction(from: .closeButton) == .nothing)
            #expect(books.closeAction(from: .menu(keyWindow: nil)) == .nothing)
            await books.press(.closeButton)?.value
            await books.press(.menu(keyWindow: nil))?.value
            prompts.answer(UnfiledDraftChoice.leaveAnyway)
            await closing?.value

            #expect(books.store.isChoosing)
            try await Task.sleep(for: .milliseconds(100))
            #expect(books.takeRequests() == [], "the ignored presses quit nothing")
            #expect(prompts.titles == ["Close without filing the copy?"], "asked once")

            await books.press(.closeButton)?.value
            #expect(
                await books.quitCarriedOut() == [quitCarriedOut], "a fresh press on the start screen quits")
            #expect(await books.settleQuit() == .left)
        }
    }

    /// Once the start screen shows, a press is decided as there, even while the close that got
    /// there is still releasing the book: it quits, rather than being dropped. The quit is asked
    /// for only once the close has ended, so the store is idle when AppKit's quit runs.
    @Test func aPressWhileTheClosedBookIsReleasedQuitsOnceTheCloseEnds() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            var releasing = false
            var decided: [BookController.CloseAction] = []
            var pressed: Task<Void, Never>?
            var closeUnderWayWhenCarriedOut: [Bool] = []
            let recorder = try #require(books.recorded)
            let storeIsBusy = recorder.storeIsBusy
            recorder.storeIsBusy = {
                closeUnderWayWhenCarriedOut.append(books.isCloseUnderWay)
                return storeIsBusy()
            }
            whenTheStartScreenShows(books.store) {
                releasing = books.isCloseUnderWay && books.store.isBusy
                decided = [
                    books.closeAction(from: .closeButton), books.closeAction(from: .menu(keyWindow: nil)),
                ]
                pressed = books.press(.menu(keyWindow: nil))
            }

            await books.press(.menu(keyWindow: nil))?.value

            try #require(releasing, "precondition: pressed while the close was still releasing the book")
            #expect(decided == [.quit, .quit])
            #expect(!books.isCloseUnderWay)
            let quit = try #require(pressed, "the quit waits for the close")
            await quit.value
            #expect(
                await books.quitCarriedOut() == [quitCarriedOut], "asked for after the close, the store idle")
            #expect(closeUnderWayWhenCarriedOut == [false], "nothing carried out while the close ran")
            #expect(await books.settleQuit() == .left)
            #expect(book.status == .closed)
            #expect(books.store.isChoosing)
        }
    }

    /// A press during the release waits for the close; if Quit's own path starts meanwhile, it
    /// takes the quit over, and the press asks AppKit for nothing.
    @Test func aPressDuringTheReleaseLeavesTheQuitToAQuitPathStartedMeanwhile() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            var pressed: Task<Void, Never>?
            var quitting: Task<AppBookStore.LeaveOutcome, Never>?
            var bothDuringTheClose = false
            whenTheStartScreenShows(books.store) {
                pressed = books.press(.closeButton)
                quitting = Task.immediate { await books.settleQuit() }
                bothDuringTheClose = books.isCloseUnderWay
            }

            await books.press(.menu(keyWindow: nil))?.value

            try #require(bothDuringTheClose, "precondition: both started while the close ran")
            let press = try #require(pressed, "precondition: the press waits for the close")
            let quit = try #require(quitting)
            await press.value
            #expect(await quit.value == .left)
            try await Task.sleep(for: .milliseconds(100))
            #expect(books.takeRequests() == [], "the quit path ended the press's quit")
            #expect(!books.isQuitUnderWay)
            #expect(books.closeAction(from: .closeButton) == .quit, "the next press is decided afresh")
        }
    }

    /// Quit's own path, started while a close is still releasing the book, queues behind the
    /// close in the store: it ends only once the book's lock is released.
    @Test func theQuitPathStartedWhileTheClosedBookIsReleasedWaitsForTheRelease() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            var startedDuringTheClose = false
            var quitting: Task<(AppBookStore.LeaveOutcome, Bool), Never>?
            whenTheStartScreenShows(books.store) {
                quitting = Task.immediate {
                    let outcome = await books.settleQuit()
                    let released =
                        if case .editing = try? BookPackage.open(at: url) { true } else { false }
                    return (outcome, released)
                }
                startedDuringTheClose = books.isCloseUnderWay && books.isQuitUnderWay
            }

            await books.press(.menu(keyWindow: nil))?.value

            try #require(startedDuringTheClose, "precondition: the quit path started while the close ran")
            let quit = try #require(quitting)
            let (outcome, released) = await quit.value
            #expect(outcome == .left)
            #expect(released, "the book's lock was released before the quit path ended")
            #expect(!books.isQuitUnderWay)
        }
    }

    /// While Close Book is asking, File a Copy and Make Editable can't start, from the menu, the
    /// toolbar or the read-only banner: what they'd collect would be torn down with the book.
    @Test func fileACopyAndMakeEditableAreOfferedOnlyWhileTheBookIsOpenNotClosing() async throws {
        try await withTemporaryFolder { folder in
            var draft = FilingDraft(today: CalendarDay(.now, in: .current))
            draft.note = "Before the ending"

            let prompts = HoldingPrompts()
            let books = BookController(role: .testHost, prompts: prompts)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            try #require(books.store.fileableBook === book, "precondition: offered while open")
            // What the toolbar's File a copy… and the File menu ask. (SwiftUI draws the toolbar's
            // and the banner's buttons itself; the test host can't see their state.)
            let filing = FilingFlow(book: book)
            try #require(filing.canBegin(in: books.store), "precondition: in the toolbar too")
            book.filingDraft = draft
            try #require(!filing.canBegin(in: books.store), "precondition: not while the dialog is up")
            let closing = books.press(.menu(keyWindow: nil))
            await eventually { prompts.titles == ["Close without filing the copy?"] }
            // The question stays up; without a draft, only the close keeps File a Copy off now.
            book.filingDraft = nil
            #expect(books.store.fileableBook == nil)
            #expect(!filing.canBegin(in: books.store), "nor in the toolbar")
            #expect(books.store.openBook == nil && books.store.current != nil, "closing, still shown")
            prompts.answer(UnfiledDraftChoice.cancel)
            await closing?.value
            #expect(books.store.fileableBook === book, "offered again after Cancel")
            #expect(filing.canBegin(in: books.store))

            let repairing = HoldingPrompts()
            let other = BookController(role: .testHost, prompts: repairing)
            let damaged = folder.appending(path: "Damaged.sceneit", directoryHint: .isDirectory)
            _ = try BookPackage.create(at: damaged, title: "Damaged")
            try Data(
                "---\ntitle: Damaged\nformat: 2\n---\n\nA stray line.\n\n## One\nid: s1\nmodified: 2026-01-01T00:00:00+00:00\n\nBody.\n"
                    .utf8
            ).write(to: damaged.appending(path: "book.md"))
            let opening = Task { await other.store.open(damaged) }
            await eventually { repairing.titles.count == 1 }
            repairing.answer(ReadOnlyChoice.keepReadOnly)
            guard case .openedReadOnly(.repairedOnOpen) = await opening.value else {
                Issue.record("precondition: the book opens repaired")
                return
            }
            try #require(other.store.canMakeEditable, "precondition: offered while open")
            let repaired = try #require(other.store.current)
            repaired.filingDraft = draft
            let closingRepaired = other.press(.menu(keyWindow: nil))
            await eventually { repairing.titles.count == 2 }
            #expect(!other.store.canMakeEditable, "neither in the menu nor on the banner")
            repairing.answer(UnfiledDraftChoice.cancel)
            await closingRepaired?.value
            #expect(other.store.canMakeEditable, "offered again after Cancel")

            repaired.filingDraft = nil
            #expect(await other.store.closeBook() == .left)
            #expect(await books.store.closeBook() == .left)
        }
    }

    /// Two presses decided while another store operation holds the store (both before it
    /// reaches `closing`) ask about closing once: the second is ignored while the first's close
    /// is unfinished, and Cancel then leaves the book open.
    @Test func pressesQueuedBehindAnotherOperationAskOnce() async throws {
        try await withTemporaryFolder { folder in
            let prompts = HoldingPrompts()
            let books = BookController(role: .testHost, prompts: prompts)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            let scene = try #require(book.addScene(after: nil))
            await eventually { book.status == .saved }
            var theirs = try bookOnDisk(url)
            theirs.title = "Their version"
            try BookFormat.serialize(theirs).write(to: url.appending(path: "book.md"), options: .atomic)
            book.setTitle(of: scene, to: "My version")
            books.store.saveNow()
            await eventually { prompts.titles == [QuitWording.changedOnDiskTitle] }
            var draft = FilingDraft(today: CalendarDay(.now, in: .current))
            draft.note = "Before the ending"
            book.filingDraft = draft
            try #require(books.store.openBook === book, "precondition: open, the close not yet begun")

            let first = books.press(.menu(keyWindow: nil))
            let second = books.press(.menu(keyWindow: nil))
            prompts.answer(ExternalChangeChoice.keepMyVersion)
            await eventually { prompts.titles.count == 2 }
            prompts.answer(UnfiledDraftChoice.cancel)
            await first?.value
            await second?.value

            #expect(prompts.titles == [QuitWording.changedOnDiskTitle, "Close without filing the copy?"])
            #expect(books.store.current === book, "Cancel kept the book open")
            book.filingDraft = nil
            #expect(await books.store.closeBook() == .left)
            #expect(books.takeRequests() == [])
        }
    }

    /// File a Copy's dialog, up when another program changes the book, is up again over the
    /// book read for Open Other Version, holding what was typed, in the window rebuilt for it.
    @Test func openOtherVersionKeepsFileACopysDialogUpAsTyped() async throws {
        try await withTemporaryFolder { folder in
            let prompts = HoldingPrompts()
            let books = BookController(role: .testHost, prompts: prompts)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            let scene = try #require(book.addScene(after: nil))
            await eventually { book.status == .saved }
            let size = WindowMetrics.defaultSize
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: MainWindow(books: books))
            window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
            window.orderFront(nil)
            defer { window.close() }
            @MainActor func sheetShowsTheNote() -> Bool {
                guard let sheet = window.attachedSheet else { return false }
                return subviewTree(of: sheet.contentView).contains {
                    ($0 as? AdmittingTextView)?.string == "Before the ending"
                }
            }
            var draft = FilingDraft(today: CalendarDay(.now, in: .current))
            draft.note = "Before the ending"
            book.filingDraft = draft
            await eventually { sheetShowsTheNote() }
            let firstSheet = try #require(window.attachedSheet, "precondition: the dialog is up")

            var theirs = try bookOnDisk(url)
            theirs.title = "Their version"
            try BookFormat.serialize(theirs).write(to: url.appending(path: "book.md"), options: .atomic)
            book.setTitle(of: scene, to: "My version")
            books.store.saveNow()
            await eventually { prompts.titles == [QuitWording.changedOnDiskTitle] }
            prompts.answer(ExternalChangeChoice.openOtherVersion)
            await eventually { books.store.current !== book && books.store.current != nil }
            let reopened = try #require(books.store.current)
            try #require(reopened.book.title == "Their version", "precondition: their version was read")

            await eventually { window.attachedSheet.map { $0 !== firstSheet } == true && sheetShowsTheNote() }
            #expect(reopened.filingDraft == draft, "nothing closing the old dialog cleared the new one's")
            #expect(prompts.titles == [QuitWording.changedOnDiskTitle], "nothing else was asked")

            reopened.filingDraft = nil
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

            await books.press(.menu(keyWindow: other))?.value

            #expect(!other.isVisible, "closed")
            #expect(books.store.current === book, "the book stays open")
            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }

    /// The whole close decision, for each state and source.
    @Test func closeActionsFollowTheStateAndTheSource() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let other = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            #expect(books.closeAction(from: .closeButton) == .quit)
            #expect(books.closeAction(from: .menu(keyWindow: nil)) == .quit)
            #expect(books.closeAction(from: .menu(keyWindow: other)) == .closeWindow(other))
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            #expect(books.closeAction(from: .closeButton) == .quit)
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
            #expect(books.store.current?.document.url.canonicalPath == url.canonicalPath)
            #expect(await books.store.closeBook() == .left)
        }
    }
}

/// The page, during the gap between a book's detach and SwiftUI's next update.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DetachedBookTypingTests {
    /// Close Book (or Open Other Version's reload) detaches the book in one main-actor job; the
    /// page stops being editable only when SwiftUI next updates it. A keystroke in between is
    /// refused by the editor itself, with a beep, and never reaches the text.
    @Test func aDetachedBooksPageRefusesTypingBeforeSwiftUICatchesUp() async throws {
        try await withPage([scene("One", [[Run("Kept.")]])]) { harness in
            let page = harness.page
            let start = harness.storage.string
            var end = NSRange(location: (start as NSString).length, length: 0)
            page.setSelectedRange(end)
            page.insertText(" More.", replacementRange: end)
            let before = harness.storage.string
            try #require(before == start + " More.", "precondition: the open book's page takes typing")
            end = NSRange(location: (before as NSString).length, length: 0)

            #expect(await harness.store.closeBook() == .left)
            try #require(!harness.book.isEditable, "precondition: detached")
            page.isEditable = true
            page.setSelectedRange(end)
            page.insertText(" Lost?", replacementRange: end)

            #expect(harness.storage.string == before, "the keystroke never reached the text")
            #expect(!page.shouldChangeText(inRanges: [NSValue(range: end)], replacementStrings: ["!"]))
        }
    }

    /// A paste on the page (`insert`, through the singular `shouldChangeText(in:replacementString:)`)
    /// is refused in the same gap: AppKit hands the singular call to the view's veto.
    @Test func aDetachedBooksPageRefusesAPasteOfCommentedText() async throws {
        try await withPage([scene("One", letterScene, .withTooEarly)]) { harness in
            try await PageHarness.withPasteboard { pasteboard in
                let page = harness.page
                let letter = NSRange(location: 4, length: 6)
                try #require((harness.storage.string as NSString).substring(with: letter) == "letter")
                harness.window.makeFirstResponder(page)
                page.setSelectedRange(letter)
                try #require(page.writeSelection(to: pasteboard, types: page.writablePasteboardTypes))
                try #require(pasteboard.types?.contains(.pageClip) == true, "precondition: our own clip")
                let start = harness.storage.string
                page.setSelectedRange(NSRange(location: 0, length: 0))
                try #require(page.readSelection(from: pasteboard))
                try #require(
                    harness.storage.string == "letter" + start, "precondition: the open book's page pastes")
                let before = harness.storage.string
                let comments = harness.book.book.scene(harness.book.openScene)?.comments

                #expect(await harness.store.closeBook() == .left)
                try #require(!harness.book.isEditable, "precondition: detached")
                page.isEditable = true
                harness.window.makeFirstResponder(page)
                page.setSelectedRange(NSRange(location: 0, length: 0))
                _ = page.readSelection(from: pasteboard)

                #expect(harness.storage.string == before, "the paste never reached the text")
                #expect(harness.book.book.scene(harness.book.openScene)?.comments == comments)
                #expect(!page.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x"))
            }
        }
    }

    /// The title field refuses typing in the same gap, as the page does.
    @Test func aDetachedBooksTitleRefusesTypingBeforeSwiftUICatchesUp() async throws {
        try await withPage([scene("One", [[Run("Kept.")]])]) { harness in
            let title = harness.title
            let scene = try #require(harness.book.openScene)
            try #require(harness.window.makeFirstResponder(title), "precondition: the title takes the focus")
            let editor = try #require(title.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.insertText(" more", replacementRange: editor.selectedRange())
            try #require(
                harness.book.book.scene(scene)?.title.text == "One more",
                "precondition: the open book's title takes typing")

            #expect(await harness.store.closeBook() == .left)
            try #require(!harness.book.isEditable, "precondition: detached")
            title.isEnabled = true
            title.isEditable = true
            try #require(
                harness.window.makeFirstResponder(title), "precondition: the field is still editable")
            let detached = try #require(title.currentEditor() as? NSTextView)
            let before = detached.string
            detached.setSelectedRange(NSRange(location: (before as NSString).length, length: 0))
            detached.insertText(" lost?", replacementRange: detached.selectedRange())

            #expect(detached.string == before, "the keystroke never reached the field")
            #expect(
                !detached.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x"),
                "the singular call `sync` makes is refused too")
            #expect(harness.book.book.scene(scene)?.title.text == "One more")
        }
    }

    /// A comment card refuses typing in the same gap, as the page does.
    @Test func aDetachedBooksCommentCardRefusesTypingBeforeSwiftUICatchesUp() async throws {
        try await withPanel { harness in
            let card = try await harness.typeInCard(noted, " Or")
            try #require(card.string == "Too early? Or", "precondition: the open book's card takes typing")

            #expect(await harness.store.closeBook() == .left)
            try #require(!harness.book.isEditable, "precondition: detached")
            card.isEditable = true
            try #require(harness.window.makeFirstResponder(card), "precondition: the card is still editable")
            let before = card.string
            card.setSelectedRange(NSRange(location: (before as NSString).length, length: 0))
            card.insertText(" late?", replacementRange: card.selectedRange())

            #expect(card.string == before, "the keystroke never reached the card")
        }
    }
}
