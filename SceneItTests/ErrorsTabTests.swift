import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// A package in `folder` whose `book.md` is `text`.
private func package(_ text: String, named name: String = "Novel", in folder: URL) throws -> URL {
    let url = folder.appending(path: "\(name).sceneit", directoryHint: .isDirectory)
    _ = try BookPackage.create(at: url, title: name)
    try Data(text.utf8).write(to: url.appending(path: "book.md"))
    return url
}

private let created = "2026-10-31T20:40:00-07:00"
private let brokenComment = "- c1 | mauve | \(created) | c12-18 | \"letter\" | Too early?"
private let strayLine = "Remember to back this up!"

/// A scene with a mistyped palette name, and a line before it that belongs nowhere.
private let damaged = """
    ---
    title: Novel
    format: 2
    ---

    \(strayLine)

    ## The ferry
    id: ferry
    modified: \(created)

    He read the letter twice.

    ### Comments
    \(brokenComment)

    """

private let newerText = "---\ntitle: Newer\nformat: 3\n---\n"

/// Hosts `view` in an offscreen window of our own.
@MainActor
private func host(_ view: some View, size: CGSize = WindowMetrics.defaultSize) async throws -> NSWindow {
    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(400))
    return window
}

@MainActor
private func views(in view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap(views)
}

/// The window's buttons, left to right, then top to bottom.
@MainActor
private func buttons(in window: NSWindow) -> [NSButton] {
    views(in: window.contentView).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        .sorted {
            let (a, b) = ($0.convert($0.bounds, to: nil), $1.convert($1.bounds, to: nil))
            return (-a.minY, a.minX) < (-b.minY, b.minX)
        }
}

/// The window's key view loop: every control Tab could reach with full keyboard access on.
/// Some SwiftUI buttons aren't `NSButton`s, but each is in the loop.
@MainActor
private func keyViews(in window: NSWindow) -> [NSView] {
    window.recalculateKeyViewLoop()
    var found: [NSView] = []
    var next = window.contentView?.nextKeyView
    while let view = next, !found.contains(view), view !== window.contentView {
        found.append(view)
        next = view.nextKeyView
    }
    return found
}

/// The selectable text the window shows: the entries' lines, as written.
@MainActor
private func selectableTexts(in window: NSWindow) -> [String] {
    views(in: window.contentView).filter { $0.accessibilityRole() == .staticText }
        .compactMap { $0.accessibilityValue() as? String }
}

/// How tall `view` wants to be, at the window's width.
@MainActor
private func height(of view: some View) -> CGFloat {
    NSHostingView(rootView: view.frame(width: WindowMetrics.defaultSize.width)).fittingSize.height
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ErrorsTabTests {
    @Test func theWindowsErrorsTabListsADamagedBooksEntries() async throws {
        try await withTemporaryFolder { folder in
            let url = try package(damaged, in: folder)
            let books = BookController(role: .testHost)
            let store = books.store
            guard case .openedReadOnly(.repairedOnOpen) = await store.open(url) else {
                Issue.record("precondition: the book opens repaired and read-only")
                return
            }
            let book = try #require(store.current)
            #expect(await store.makeEditable() == .editable)
            books.preferences.showRightPanelTab(.errors)
            let window = try await host(
                BookWindow(
                    book: book, store: store, preferences: books.preferences, formatting: books.formatting,
                    mode: .constant(.page)))
            defer { window.close() }
            let shown = selectableTexts(in: window)
            #expect(shown.contains(brokenComment), "\(shown)")
            #expect(shown.contains(strayLine), "\(shown)")
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func thePanelGoesBackToCommentsWhenTheLastEntryIsDeleted() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            _ = await store.open(try package(damaged, in: folder))
            let book = try #require(store.current)
            #expect(await store.makeEditable() == .editable)
            books.preferences.showRightPanelTab(.errors)
            let window = try await host(
                BookWindow(
                    book: book, store: store, preferences: books.preferences, formatting: books.formatting,
                    mode: .constant(.page)))
            defer { window.close() }
            try #require(
                selectableTexts(in: window).contains(strayLine), "precondition: the Errors tab shows")
            while let ref = book.book.errorGroups.first?.refs.first {
                #expect(book.deleteError(ref))
                try await Task.sleep(for: .milliseconds(100))
                if book.book.errorCount > 0 { #expect(books.preferences.rightPanelTab == .errors) }
            }
            await eventually { books.preferences.rightPanelTab == .comments }
            #expect(!selectableTexts(in: window).contains(strayLine))
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func deleteActsOnTheBookOnlyOnceItsEditable() async throws {
        try await withTemporaryFolder { folder in
            let url = try package(damaged, in: folder)
            let books = BookController(role: .testHost)
            let store = books.store
            _ = await store.open(url)
            let book = try #require(store.current)
            try #require(book.book.errorCount == 2, "precondition: the line and the comment")
            let size = CGSize(width: WindowMetrics.panelWidth, height: 700)
            do {
                let window = try await host(ErrorsTab(book: book), size: size)
                defer { window.close() }
                let actions = buttons(in: window)
                #expect(
                    actions.count == 2 + 3,
                    "Copy and Delete for the line; Copy, Fix and Delete for the comment")
                #expect(
                    actions.filter { $0.isEnabled }.count == 2,
                    "a read-only book's entries can only be copied")
            }

            #expect(await store.makeEditable() == .editable)
            await eventually { book.status == .saved }
            let window = try await host(ErrorsTab(book: book), size: size)
            defer { window.close() }
            let actions = buttons(in: window)
            #expect(actions.allSatisfy { $0.isEnabled })
            let deleteLine = try #require(actions.dropFirst().first)
            deleteLine.performClick(nil)
            #expect(book.book.errors.isEmpty, "the book-level line went")
            #expect(book.book.errorCount == 1)
            #expect(book.status == .unsaved, "the deletion reached autosave")
            book.structureUndo.undo()
            #expect(book.book.errorCount == 2)
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func theBannerShowsForTheReadOnlyReasonsAboutTheBooksContent() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            @MainActor func banner() throws -> some View {
                ReadOnlyBanner(
                    book: try #require(store.current), store: store, preferences: books.preferences)
            }

            guard case .openedReadOnly(.repairedOnOpen) = await store.open(try package(damaged, in: folder))
            else {
                Issue.record("precondition: the book opens repaired and read-only")
                return
            }
            try #expect(height(of: banner()) > 30)
            do {
                let window = try await host(try banner(), size: CGSize(width: 1000, height: 100))
                defer { window.close() }
                #expect(keyViews(in: window).count == 2, "Show Repairs and Make Editable…")
            }
            #expect(await store.makeEditable() == .editable)
            try #expect(height(of: banner()) == 0, "gone once the book is editable")
            #expect(await store.closeBook() == .left)

            #expect(
                await store.open(try package(newerText, named: "Newer", in: folder))
                    == .openedReadOnly(.newerFormat(FormatVersion(3))))
            try #expect(height(of: banner()) > 30)
            do {
                let window = try await host(try banner(), size: CGSize(width: 1000, height: 100))
                defer { window.close() }
                #expect(keyViews(in: window).isEmpty, "a newer book can't be made editable here")
            }
            #expect(await store.closeBook() == .left)

            let held = folder.appending(path: "Held.sceneit", directoryHint: .isDirectory)
            let holder = try BookPackage.create(at: held, title: "Held")
            #expect(await store.open(held) == .openedReadOnly(.openElsewhere))
            try #expect(height(of: banner()) == 0, "the status bar and the alert cover a lock")
            #expect(await store.closeBook() == .left)
            withExtendedLifetime(holder) {}
        }
    }

    @Test func copyPutsThePayloadOnThePasteboardAsPlainText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SceneItTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        EntryClipboard.copy(ErrorEntry(.comments, brokenComment), to: pasteboard)
        #expect(pasteboard.string(forType: .string) == brokenComment)
        #expect(pasteboard.pasteboardItems?.count == 1)
    }
}

extension BookStoreIntegrationTests {
    private var makeEditableItem: NSMenuItem? {
        if let menu = menuItem(titled: ErrorsWording.makeEditableItem, in: NSApp.mainMenu)?.menu {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
        }
        return menuItem(titled: ErrorsWording.makeEditableItem, in: NSApp.mainMenu)
    }

    @Test func makeEditableIsInTheFileMenuOnlyForARepairedBook() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.current == nil)
            #expect(makeEditableItem != nil)
            await eventually { makeEditableItem?.isEnabled == false }

            let newer = try package(newerText, named: "Newer", in: folder)
            #expect(await store.open(newer) == .openedReadOnly(.newerFormat(FormatVersion(3))))
            try await Task.sleep(for: .milliseconds(100))
            #expect(makeEditableItem?.isEnabled == false)

            guard case .openedReadOnly(.repairedOnOpen) = await store.open(try package(damaged, in: folder))
            else {
                Issue.record("precondition: the book opens repaired and read-only")
                return
            }
            await eventually { makeEditableItem?.isEnabled == true }
            let headless = try #require(books.prompts as? HeadlessPrompts)
            #expect(headless.takeTitles() == [ReadOnlyWording.readOnlyTitle, ReadOnlyWording.readOnlyTitle])
            try perform(try #require(makeEditableItem))
            await eventually { headless.titles == [ReadOnlyWording.makeEditableTitle] }
            let book = try #require(store.current)
            #expect(!book.isEditable, "it asks first, and the test host answers Keep Read-Only")
            #expect(headless.takeTitles() == [ReadOnlyWording.makeEditableTitle])

            #expect(await store.makeEditable() == .editable)
            await eventually { makeEditableItem?.isEnabled == false }
            #expect(await store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}
