import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Waits for the run loop to turn, as it does after each event, so the undo manager closes the
/// group it opened for the last change.
@MainActor
private func eventEnds(_ undo: UndoManager) async {
    await eventually { undo.groupingLevel == 0 }
}

/// Runs `body` with the undo manager grouping only as `anEvent` says. A test has no events, and
/// AppKit closes the group it opens for an event's first change only at the end of that event;
/// so a test that wants an undo step per command opens and closes the groups itself, as AppKit
/// does around each event.
@MainActor
private func asSeparateEvents(_ undo: UndoManager, _ body: () throws -> Void) rethrows {
    undo.groupsByEvent = false
    defer { undo.groupsByEvent = true }
    try body()
}

@MainActor
private func anEvent(_ undo: UndoManager, _ body: () throws -> Void) rethrows {
    undo.beginUndoGrouping()
    defer { undo.endUndoGrouping() }
    try body()
}

/// Each command, the scene it's applied to (all of it selected), and the body it leaves.
private let cases: [(FormattingCommand, [Paragraph], [Paragraph])] = [
    (
        .toggle(.bold), [[Run("Plain "), Run("bold", styles: [.bold])]],
        [[Run("Plain bold", styles: [.bold])]]
    ),
    (.toggle(.bold), [[Run("All bold", styles: [.bold])]], [[Run("All bold")]]),
    (.toggle(.italic), [[Run("Words.")]], [[Run("Words.", styles: [.italic])]]),
    (.toggle(.strike), [[Run("Words.")]], [[Run("Words.", styles: [.strike])]]),
    (
        .textColor(.red), [[Run("The "), Run("letter", comments: [noted])]],
        [[Run("The ", color: .red), Run("letter", color: .red, comments: [noted])]]
    ),
    (.textColor(.black), [[Run("Purple", color: .purple)]], [[Run("Purple")]]),
    (
        .highlight(.blue), [[Run("Words.", styles: [.italic])]],
        [[Run("Words.", styles: [.italic], highlight: .blue)]]
    ),
    (.highlight(nil), [[Run("Lit", highlight: .green)]], [[Run("Lit")]]),
]

@Suite(.serialized, .timeLimit(.minutes(2)))
struct FormattingBarTests {
    /// The bar's buttons and palettes call `PageFormatting.perform`.
    @Test func aCommandFromTheBarFormatsTheSelectionAsOneUndoableStep() async throws {
        for (command, before, after) in cases {
            try await formatsAsOneUndoableStep(command, before, after)
        }
    }

    private func formatsAsOneUndoableStep(
        _ command: FormattingCommand, _ before: [Paragraph], _ after: [Paragraph]
    ) async throws {
        try await withPage([scene("One", before, .withTooEarly)]) { page in
            await eventually { page.book.status == .saved }
            page.focusPage(at: 0)
            page.page.selectAll(nil)
            let undo = try #require(page.page.undoManager)
            await eventEnds(undo)
            #expect(page.formatting.selection != nil, "precondition: the page can be formatted")

            page.formatting.perform(command)
            #expect(page.body() == after)
            #expect(page.pageMirrorsModel)
            #expect(page.book.status == .unsaved, "autosave heard of it in the same turn")
            #expect(undo.undoActionName == WindowWording.undoName(command))
            page.store.saveNow()
            await eventually { page.book.status == .saved }
            #expect(try bookOnDisk(page.url).scenes.first?.body == after)

            undo.undo()
            #expect(page.body() == before, "one step undoes it")
            #expect(page.pageMirrorsModel)
            undo.redo()
            #expect(page.body() == after)
        }
    }

    @Test func theBarShowsTheSelectionsState() async throws {
        let body: [Paragraph] = [[Run("Bold", styles: [.bold]), Run(" plain")]]
        try await withPage([scene("One", body)]) { page in
            page.focusPage(at: 0)
            page.page.setSelectedRange(NSRange(location: 0, length: 4))
            #expect(page.formatting.state(of: .toggle(.bold)) == .on)
            page.page.setSelectedRange(NSRange(location: 0, length: 6))
            #expect(page.formatting.state(of: .toggle(.bold)) == .mixed)
            page.page.setSelectedRange(NSRange(location: 6, length: 3))
            #expect(page.formatting.state(of: .toggle(.bold)) == .off)

            page.formatting.perform(.toggle(.italic))
            #expect(page.formatting.state(of: .toggle(.italic)) == .on, "refreshed after a command")
        }
    }

    @Test func typingAfterAToggleWithNothingSelectedUsesTheToggledStyle() async throws {
        try await withPage([scene("One", [[Run("Start.")]])]) { page in
            page.focusPage(at: 6)
            page.formatting.perform(.toggle(.bold))
            page.formatting.perform(.textColor(.green))
            #expect(page.formatting.state(of: .toggle(.bold)) == .on, "the caret shows what typing gives")
            #expect(page.body() == [[Run("Start.")]], "nothing selected: the text is unchanged")
            page.page.insertText(" Next", replacementRange: page.page.selectedRange())
            #expect(page.body() == [[Run("Start."), Run(" Next", styles: [.bold], color: .green)]])
            #expect(page.pageMirrorsModel)

            page.formatting.perform(.toggle(.bold))
            page.page.insertText(".", replacementRange: page.page.selectedRange())
            #expect(
                page.body() == [
                    [Run("Start."), Run(" Next", styles: [.bold], color: .green), Run(".", color: .green)]
                ])
        }
    }

    @Test func aChosenColorBecomesTheBarsColorButton() async throws {
        try await withPage([scene("One", [[Run("Words.")]])]) { page in
            page.focusPage(at: 0)
            page.page.selectAll(nil)
            #expect(
                PaletteKind.textColor.lastUsed(page.formatting.preferences).command == .textColor(.purple))
            page.formatting.perform(.textColor(.red))
            #expect(PaletteKind.textColor.lastUsed(page.formatting.preferences).command == .textColor(.red))
            page.formatting.perform(.textColor(.black))
            #expect(
                PaletteKind.textColor.lastUsed(page.formatting.preferences).command == .textColor(.red),
                "black removes; it isn't remembered")
            page.formatting.perform(.highlight(.pink))
            #expect(PaletteKind.highlight.lastUsed(page.formatting.preferences).command == .highlight(.pink))
            #expect(page.book.book.scenes.first?.body == [[Run("Words.", highlight: .pink)]])
        }
    }

    /// Decision 0015: the title is plain text, so the bar is inactive while it has the focus.
    @Test func theBarIsInactiveUnlessThePageHasTheFocus() async throws {
        try await withPage([scene("One", [[Run("Words.")]])]) { page in
            page.focusPage(at: 0)
            #expect(page.formatting.selection != nil)
            #expect(page.window.makeFirstResponder(page.title))
            #expect(page.title.currentEditor() != nil, "precondition: the title has the focus")
            #expect(page.formatting.selection == nil)
            page.formatting.perform(.toggle(.bold))
            #expect(page.book.book.scenes.first?.body == [[Run("Words.")]], "nothing formatted")
            #expect(
                PaletteKind.textColor.lastUsed(page.formatting.preferences).command == .textColor(.purple))

            page.focusPage(at: 0)
            #expect(page.formatting.selection != nil)
            page.window.makeFirstResponder(nil)
            #expect(page.formatting.selection == nil)
        }
    }

    @Test func theBarIsInactiveInAReadOnlyBook() async throws {
        try await withPage([scene("One", [[Run("Words.")]])], holdingTheLock: true) { page in
            page.window.makeFirstResponder(page.page)
            page.page.selectAll(nil)
            #expect(!page.page.isEditable, "precondition: read-only")
            #expect(page.formatting.selection == nil)
        }
    }
}

extension FormattingBarTests {
    @Test func commandsInSeparateEventsAreSeparateUndoSteps() async throws {
        try await withPage([scene("One", [[Run("Words.")]])]) { page in
            page.focusPage(at: 0)
            page.page.selectAll(nil)
            let undo = try #require(page.page.undoManager)
            await eventEnds(undo)
            asSeparateEvents(undo) {
                anEvent(undo) { page.formatting.perform(.toggle(.bold)) }
                anEvent(undo) { page.formatting.perform(.textColor(.blue)) }
            }
            #expect(page.body() == [[Run("Words.", styles: [.bold], color: .blue)]])
            #expect(undo.undoActionName == WindowWording.undoName(.textColor(.blue)))
            undo.undo()
            #expect(page.body() == [[Run("Words.", styles: [.bold])]])
            #expect(undo.undoActionName == WindowWording.undoName(.toggle(.bold)))
            undo.undo()
            #expect(page.body() == [[Run("Words.")]])
        }
    }

    /// A command can arrive while the typing's undo group is still open (in one event, or a key
    /// equivalent's burst before the group closes): it joins the group, and nothing raises.
    @Test func aCommandWhileTheTypingsUndoGroupIsOpenJoinsIt() async throws {
        try await withPage([scene("One", [[Run("Words.")]])]) { page in
            page.focusPage(at: 6)
            page.page.insertText(" More.", replacementRange: page.page.selectedRange())
            let undo = try #require(page.page.undoManager)
            #expect(undo.groupingLevel == 1, "precondition: the typing's group is open")
            page.page.selectAll(nil)
            page.formatting.perform(.toggle(.bold))
            page.formatting.perform(.toggle(.italic))
            #expect(page.body() == [[Run("Words. More.", styles: [.bold, .italic])]])
            #expect(page.pageMirrorsModel)
            undo.undo()
            #expect(page.body() == [[Run("Words.")]])
        }
    }
}

extension FormattingBarTests {
    /// An undo or redo of formatting leaves the selection where it was; the bar follows anyway.
    @Test func theBarFollowsUndoAndRedo() async throws {
        try await withPage([scene("One", [[Run("Words here.")]])]) { page in
            page.focusPage(at: 0)
            let undo = try #require(page.page.undoManager)
            await eventually { undo.groupingLevel == 0 }
            let selection = NSRange(location: 0, length: 5)
            await inAnEvent(undo) { page.page.setSelectedRange(selection) }
            await inAnEvent(undo) { page.formatting.perform(.toggle(.bold)) }
            #expect(page.formatting.state(of: .toggle(.bold)) == .on)
            await undoInAnEvent(undo)
            #expect(page.body() == [[Run("Words here.")]])
            #expect(page.page.selectedRange() == selection, "precondition: the selection didn't move")
            #expect(page.formatting.state(of: .toggle(.bold)) == .off, "after undo")
            await undoInAnEvent(undo, .redo)
            #expect(page.page.selectedRange() == selection, "precondition: the selection didn't move")
            #expect(page.formatting.state(of: .toggle(.bold)) == .on, "after redo")
        }
    }

    @Test func theBarIsInactiveUnderASheet() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            let scene = try #require(book.addScene(after: nil))
            book.replaceBody(of: scene, with: [[Run("Words.")]])
            let box = ModeBox()
            let size = WindowMetrics.defaultSize
            let controller = NSHostingController(
                rootView: BookWindowWithMode(
                    book: book, store: books.store, preferences: books.preferences,
                    formatting: books.formatting, box: box))
            controller.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
            window.orderFront(nil)
            defer { window.close() }
            await eventually { subviewTree(of: window.contentView).contains { $0 is ManuscriptTextView } }
            let view = try #require(
                subviewTree(of: window.contentView).compactMap { $0 as? ManuscriptTextView }.first)
            await eventually { view.string == "Words." && view.isEditable }
            #expect(window.makeFirstResponder(view))
            view.selectAll(nil)
            #expect(books.formatting.selection != nil, "precondition: the page can be formatted")
            box.mode = .scenes
            await eventually { !view.isEditable }
            #expect(books.formatting.selection == nil, "inactive under a sheet")
            books.formatting.perform(.toggle(.bold))
            #expect(book.book.scene(scene)?.body == [[Run("Words.")]])
            box.mode = .page
            await eventually { view.isEditable }
            #expect(await books.store.closeBook() == .left)
        }
    }
}

// MARK: The Format menu

extension FormattingCommand {
    /// The command's item in the app's Format menu, after asking SwiftUI to refresh it.
    @MainActor
    var menuItem: NSMenuItem? {
        let format = Self.updated(
            NSApp.mainMenu?.items.first { $0.title == WindowWording.formatMenu }?.submenu)
        let menu: NSMenu? =
            switch self {
            case .toggle: format
            case .textColor:
                Self.updated(format?.items.first { $0.title == WindowWording.textColor }?.submenu)
            case .highlight:
                Self.updated(format?.items.first { $0.title == WindowWording.highlight }?.submenu)
            }
        return menu?.items.first { $0.title == WindowWording.menuItem(self) }
    }

    /// SwiftUI may replace a menu's items, submenus included, when it updates; so each menu is
    /// updated before its items are read.
    @MainActor
    private static func updated(_ menu: NSMenu?) -> NSMenu? {
        guard let menu else { return nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        return menu
    }
}

extension BookStoreIntegrationTests {
    @Test func theFormatMenuHasEveryCommandWithItsShortcut() throws {
        let expected: [(FormattingCommand, String, NSEvent.ModifierFlags)] =
            [
                (.toggle(.bold), "b", [.command]), (.toggle(.italic), "i", [.command]),
                (.toggle(.strike), "x", [.command, .shift]),
            ]
            + PaletteColor.allCases.enumerated().map { index, color in
                (.textColor(color), "\(index + 1)", [.control, .command])
            }
            + FormattingCommand.highlights.map { ($0, "", []) }
        for (command, key, modifiers) in expected {
            let item = try #require(command.menuItem, "\(command)")
            #expect(item.keyEquivalent == key, "\(command)")
            if !key.isEmpty {
                #expect(item.keyEquivalentModifierMask == modifiers, "\(command)")
            }
        }
    }

    /// The real path: the app's own window and store, and its Format menu.
    @Test func theFormatMenuFormatsThePageAndIsDisabledElsewhere() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.current == nil)
            await eventually { FormattingCommand.toggle(.bold).menuItem?.isEnabled == false }

            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            book.replaceBody(of: scene, with: [[Run("From "), Run("the menu.", color: .red)]])
            @MainActor func page() -> ManuscriptTextView? {
                NSApp.windows.lazy.flatMap { subviewTree(of: $0.contentView) }
                    .compactMap { $0 as? ManuscriptTextView }.first { $0.string == "From the menu." }
            }
            await eventually { page() != nil }
            let view = try #require(page())
            let window = try #require(view.window)
            #expect(books.formatting.selection == nil, "the page doesn't have the focus yet")
            #expect(FormattingCommand.toggle(.bold).menuItem?.isEnabled == false)

            #expect(window.makeFirstResponder(view))
            view.selectAll(nil)
            await eventually { FormattingCommand.toggle(.bold).menuItem?.isEnabled == true }
            #expect(
                FormattingCommand.textColors.allSatisfy { $0.menuItem?.state == .off },
                "two colors selected: no color is checked")
            #expect(FormattingCommand.highlight(nil).menuItem?.state == .on, "None is checked")

            let undo = try #require(view.undoManager)
            let commands: [FormattingCommand] = [.toggle(.bold), .textColor(.blue), .highlight(.gray)]
            try asSeparateEvents(undo) {
                for command in commands {
                    try anEvent(undo) {
                        try perform(try #require(command.menuItem, "\(command)"))
                    }
                    #expect(undo.undoActionName == WindowWording.undoName(command))
                }
            }
            let formatted: [Paragraph] = [
                [Run("From the menu.", styles: [.bold], color: .blue, highlight: .gray)]
            ]
            #expect(book.book.scene(scene)?.body == formatted)
            await eventually { FormattingCommand.textColor(.blue).menuItem?.state == .on }
            #expect(FormattingCommand.textColor(.black).menuItem?.state == .off)
            #expect(FormattingCommand.highlight(.gray).menuItem?.state == .on)
            #expect(FormattingCommand.highlight(nil).menuItem?.state == .off)
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes.first { $0.id == scene }?.body == formatted)
            undo.undo()
            #expect(
                book.book.scene(scene)?.body == [[Run("From the menu.", styles: [.bold], color: .blue)]],
                "one undo takes one command away")

            window.makeFirstResponder(nil)
            await eventually { FormattingCommand.toggle(.bold).menuItem?.isEnabled == false }
            #expect(await store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}

extension BookStoreIntegrationTests {
    /// Decision 0027 keeps Cmd+1 for Scenes; no two menu items share a key equivalent.
    @Test func noTwoMenuItemsShareAKeyEquivalent() {
        @MainActor func items(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { item -> [NSMenuItem] in
                if let submenu = item.submenu {
                    submenu.delegate?.menuNeedsUpdate?(submenu)
                    submenu.update()
                }
                return [item] + items(item.submenu)
            }
        }
        let withKeys = items(NSApp.mainMenu).filter { !$0.keyEquivalent.isEmpty }
        #expect(withKeys.count > 20, "precondition: the whole menu bar was read")
        let byKey = Dictionary(grouping: withKeys) {
            "\($0.keyEquivalent) \($0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue)"
        }
        let shared = byKey.filter { $0.value.count > 1 }.mapValues { $0.map(\.title) }
        #expect(shared.isEmpty, "\(shared)")
    }

    @Test func closingTheBookWithThePageFocusedDisablesTheMenu() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.current == nil)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            book.replaceBody(of: scene, with: [[Run("Close me.")]])
            @MainActor func page() -> ManuscriptTextView? {
                NSApp.windows.lazy.flatMap { subviewTree(of: $0.contentView) }
                    .compactMap { $0 as? ManuscriptTextView }.first { $0.string == "Close me." }
            }
            await eventually { page() != nil }
            let view = try #require(page())
            #expect(view.window?.makeFirstResponder(view) == true)
            view.selectAll(nil)
            await eventually { FormattingCommand.toggle(.bold).menuItem?.isEnabled == true }
            #expect(await store.closeBook() == .left)
            await eventually { page() == nil }
            #expect(books.formatting.selection == nil, "nothing to format once the book is closed")
            await eventually { FormattingCommand.toggle(.bold).menuItem?.isEnabled == false }
        }
    }
}
