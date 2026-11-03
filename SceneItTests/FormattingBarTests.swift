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
            #expect(page.formatting.lastTextColor == .textColor(.purple))
            page.formatting.perform(.textColor(.red))
            #expect(page.formatting.lastTextColor == .textColor(.red))
            page.formatting.perform(.textColor(.black))
            #expect(page.formatting.lastTextColor == .textColor(.red), "black removes; it isn't remembered")
            page.formatting.perform(.highlight(.pink))
            #expect(page.formatting.lastHighlight == .highlight(.pink))
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
            #expect(page.formatting.lastTextColor == .textColor(.purple))

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
            book.replaceBody(of: scene, with: [[Run("From the menu.")]])
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
            let undo = try #require(view.undoManager)
            for command in [FormattingCommand.toggle(.bold), .textColor(.blue), .highlight(.gray)] {
                try perform(try #require(command.menuItem, "\(command)"))
                #expect(undo.undoActionName == WindowWording.undoName(command))
            }
            let formatted: [Paragraph] = [
                [Run("From the menu.", styles: [.bold], color: .blue, highlight: .gray)]
            ]
            #expect(book.book.scene(scene)?.body == formatted)
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes.first { $0.id == scene }?.body == formatted)
            // With no events between them, the three commands share one undo group.
            undo.undo()
            #expect(book.book.scene(scene)?.body == [[Run("From the menu.")]])

            window.makeFirstResponder(nil)
            await eventually { FormattingCommand.toggle(.bold).menuItem?.isEnabled == false }
            #expect(await store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}
