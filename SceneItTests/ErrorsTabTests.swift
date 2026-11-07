import AppKit
import SceneItCore
import SceneItTestSupport
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

/// The book's window, hosted offscreen once its Errors tab shows the stray line.
@MainActor
private func hostWindowShowingTheStrayLine(_ view: some View) async -> NSWindow {
    await hostOffscreen(view, size: WindowMetrics.defaultSize) { selectableTexts(in: $0).contains(strayLine) }
}

/// The banner, hosted offscreen above a view of the test's own. SwiftUI makes the banner's
/// controls in the same update as that view, so once it's there, the banner's are too, even
/// when the banner has none.
@MainActor
private func hostBanner(_ banner: some View) async -> NSWindow {
    await hostOffscreen(
        VStack {
            banner
            MarkerView()
        }, size: CGSize(width: 1000, height: 140)
    ) { window in
        subviewTree(of: window.contentView).contains { $0 is MarkerView.Marker }
    }
}

private struct MarkerView: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ marker: Marker, context: Context) {}
}

/// The key view loop of a window from `hostBanner`, without the marker or SwiftUI's host for it.
@MainActor
private func bannerKeyViews(in window: NSWindow) -> [NSView] {
    keyViews(in: window).filter { view in !subviewTree(of: view).contains { $0 is MarkerView.Marker } }
}

/// The window's buttons, left to right, then top to bottom.
@MainActor
private func buttons(in window: NSWindow) -> [NSButton] {
    subviewTree(of: window.contentView).compactMap { $0 as? NSButton }.filter {
        !$0.isHiddenOrHasHiddenAncestor
    }
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

/// The selectable text the window shows: the entries' lines, as written. SwiftUI may keep a
/// removed entry's view in the window, hidden.
@MainActor
private func selectableTexts(in window: NSWindow) -> [String] {
    subviewTree(of: window.contentView)
        .filter { $0.accessibilityRole() == .staticText && !$0.isHiddenOrHasHiddenAncestor }
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
            let window = await hostWindowShowingTheStrayLine(
                BookWindow(
                    book: book, store: store, preferences: books.preferences, formatting: books.formatting,
                    mode: .constant(.page)))
            defer { window.close() }
            let shown = selectableTexts(in: window)
            #expect(shown.contains(brokenComment), "\(shown)")
            #expect(shown.contains(strayLine), "\(shown)")
            #expect(await store.prepareToQuit() == .left)
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
            let window = await hostWindowShowingTheStrayLine(
                BookWindow(
                    book: book, store: store, preferences: books.preferences, formatting: books.formatting,
                    mode: .constant(.page)))
            defer { window.close() }
            try #require(
                selectableTexts(in: window).contains(strayLine), "precondition: the Errors tab shows")
            @MainActor func entriesShown() -> Int {
                selectableTexts(in: window).filter { [strayLine, brokenComment].contains($0) }.count
            }
            try #require(entriesShown() == 2, "precondition: the line and the comment")
            while let ref = book.book.errorGroups.first?.refs.first {
                #expect(book.deleteError(ref))
                if book.book.errorCount > 0 {
                    // The update that drops the entry is the one whose onChange would switch tabs.
                    await eventually { entriesShown() == book.book.errorCount }
                    #expect(books.preferences.rightPanelTab == .errors)
                }
            }
            await eventually { books.preferences.rightPanelTab == .comments }
            // The window re-renders on a later turn, later still on a busy machine.
            await eventually { !selectableTexts(in: window).contains(strayLine) }
            #expect(await store.prepareToQuit() == .left)
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
                let window = await hostOffscreen(ErrorsTab(book: book), size: size) {
                    buttons(in: $0).count == 2 + 3
                }
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
            let window = await hostOffscreen(ErrorsTab(book: book), size: size) {
                buttons(in: $0).count == 2 + 3 && buttons(in: $0).allSatisfy(\.isEnabled)
            }
            defer { window.close() }
            let actions = buttons(in: window)
            #expect(actions.allSatisfy { $0.isEnabled })
            let deleteLine = try #require(actions.dropFirst().first)
            deleteLine.performClick(nil)
            #expect(
                (window.firstResponder as? UndoFocusView)?.focus == .errorsTab,
                "Delete gives the tab the focus, so Undo then undoes the deletion")
            #expect(book.book.errors.isEmpty, "the book-level line went")
            #expect(book.book.errorCount == 1)
            #expect(book.status == .unsaved, "the deletion reached autosave")
            book.errorsUndo.undo()
            #expect(book.book.errorCount == 2)
            #expect(await store.prepareToQuit() == .left)
        }
    }

    /// After a deletion the tab keeps the focus, ringed, and Undo undoes the deletion from
    /// the tab's own history; the Scenes sheet and the page never reach it, and Esc goes back
    /// to the page.
    @Test func afterDeletingAnEntryTheTabKeepsTheFocusAndUndoesItsOwnHistory() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            _ = await store.open(try package(damaged, in: folder))
            let book = try #require(store.current)
            #expect(await store.makeEditable() == .editable)
            books.preferences.showRightPanelTab(.errors)
            let modes = ModeBox()
            let window = await hostOffscreen(
                BookWindowWithMode(book: book, store: store, preferences: books.preferences, box: modes),
                size: WindowMetrics.defaultSize
            ) { window in
                let tree = subviewTree(of: window.contentView)
                return tree.contains { $0 is ManuscriptTextView }
                    && tree.contains { ($0 as? UndoFocusView)?.focus == .errorsTab }
            }
            defer { window.close() }
            let routers = subviewTree(of: window.contentView).compactMap {
                ($0 as? UndoRouterWindow.WindowView)?.router
            }
            let router = try #require(routers.first)
            let page = try #require(
                subviewTree(of: window.contentView).compactMap { $0 as? ManuscriptTextView }.first)
            let scene = try #require(book.openScene)
            #expect(window.makeFirstResponder(page))
            window.update()
            #expect(router.manager === book.pageUndo(for: scene))

            // What the tab's Delete does (deleteActsOnTheBookOnlyOnceItsEditable clicks it).
            let tabs = subviewTree(of: window.contentView).compactMap { $0 as? UndoFocusView }
            let tab = try #require(tabs.first { $0.focus == .errorsTab })
            tab.takeFocus()
            #expect(book.deleteError(try #require(book.book.errorGroups.first?.refs.first)))
            #expect(book.book.errorCount == 1)
            window.update()
            #expect(tab.hasFocus && tab.showsFocusRing, "the tab keeps the focus, and shows it")
            #expect(router.stack == .errors)
            #expect(router.state.undo == "Undo \(ErrorsWording.deleteUndoName)")
            #expect(!book.structureUndo.canUndo, "the Errors tab's history is its own")

            router.undo()
            #expect(book.book.errorCount == 2, "the entry is back")
            #expect(
                router.state.redo == "Redo \(ErrorsWording.deleteUndoName)", "at once, without another event")
            router.redo()
            #expect(book.book.errorCount == 1)

            modes.mode = .scenes
            await eventually { window.firstResponder is UndoFocusView && router.mode == .scenes }
            window.update()
            #expect(router.manager === book.structureUndo)
            #expect(router.state == .nothing, "the Scenes sheet doesn't undo a deletion it doesn't show")
            router.undo()
            #expect(book.book.errorCount == 1)
            modes.mode = .page
            await eventually { router.mode == .page }

            tab.takeFocus()
            window.update()
            #expect(router.stack == .errors)
            tab.cancelOperation(nil)
            #expect(window.firstResponder === page, "Esc goes back to the page")
            window.update()
            #expect(router.manager === book.pageUndo(for: scene), "and Undo to the page's history")
            #expect(await store.prepareToQuit() == .left)
        }
    }

    @Test func theBannerShowsForTheReadOnlyReasonsAboutTheBooksContent() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            @MainActor func banner() throws -> some View {
                ReadOnlyBanner(
                    book: try #require(books.store.current), store: books.store,
                    preferences: books.preferences)
            }

            guard
                case .openedReadOnly(.repairedOnOpen) = await books.store.open(
                    try package(damaged, in: folder))
            else {
                Issue.record("precondition: the book opens repaired and read-only")
                return
            }
            try #expect(height(of: banner()) > 30)
            do {
                let window = await hostBanner(try banner())
                defer { window.close() }
                #expect(bannerKeyViews(in: window).count == 2, "Show Repairs and Make Editable…")
            }
            #expect(await books.store.makeEditable() == .editable)
            try #expect(height(of: banner()) == 0, "gone once the book is editable")
            #expect(await books.quitAndRelaunch() == .left)

            #expect(
                await books.store.open(try package(newerText, named: "Newer", in: folder))
                    == .openedReadOnly(.newerFormat(FormatVersion(3))))
            try #expect(height(of: banner()) > 30)
            do {
                let window = await hostBanner(try banner())
                defer { window.close() }
                #expect(bannerKeyViews(in: window).isEmpty, "a newer book can't be made editable here")
            }
            #expect(await books.quitAndRelaunch() == .left)

            let held = folder.appending(path: "Held.sceneit", directoryHint: .isDirectory)
            let holder = try BookPackage.create(at: held, title: "Held")
            #expect(await books.store.open(held) == .openedReadOnly(.openElsewhere))
            try #expect(height(of: banner()) == 0, "the status bar and the alert cover a lock")
            #expect(await books.quitAndRelaunch() == .left)
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
            try #require(books.store.current == nil)
            #expect(makeEditableItem != nil)
            await eventually { makeEditableItem?.isEnabled == false }

            let repaired = try package(damaged, in: folder)
            guard case .openedReadOnly(.repairedOnOpen) = await books.store.open(repaired) else {
                Issue.record("precondition: the book opens repaired and read-only")
                return
            }
            await eventually { makeEditableItem?.isEnabled == true }
            #expect(await books.quitAndRelaunch() == .left)
            let newer = try package(newerText, named: "Newer", in: folder)
            #expect(await books.store.open(newer) == .openedReadOnly(.newerFormat(FormatVersion(3))))
            await eventually { makeEditableItem?.isEnabled == false }

            #expect(await books.quitAndRelaunch() == .left)
            guard case .openedReadOnly(.repairedOnOpen) = await books.store.open(repaired) else {
                Issue.record("precondition: the book opens repaired and read-only again")
                return
            }
            await eventually { makeEditableItem?.isEnabled == true }
            let headless = try #require(books.prompts as? HeadlessPrompts)
            #expect(headless.takeTitles() == Array(repeating: ReadOnlyWording.readOnlyTitle, count: 3))
            try perform(try #require(makeEditableItem))
            await eventually { headless.titles == [ReadOnlyWording.makeEditableTitle] }
            let book = try #require(books.store.current)
            #expect(!book.isEditable, "it asks first, and the test host answers Keep Read-Only")
            #expect(headless.takeTitles() == [ReadOnlyWording.makeEditableTitle])

            #expect(await books.store.makeEditable() == .editable)
            await eventually { makeEditableItem?.isEnabled == false }
            #expect(await books.quitAndRelaunch() == .left)
            expectNoQuestions()
        }
    }
}
