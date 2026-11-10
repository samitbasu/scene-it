import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// ADR 0049: no text in Scene It reaches a language model. Every text view a writer can type
/// in, and every field's editor, has Apple Intelligence's Writing Tools and word predictions
/// (inline, and the Touch Bar's candidates) off, and the menus offer no Writing Tools.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct LanguageModelsOffTests {
    /// The book window's view tree in each of its states: the page with each right-panel tab,
    /// the find bar, each sheet, and File a Copy's dialog. Every field takes the focus, so its
    /// editor is the one it types with.
    @Test func everyTextViewInTheWindowHasLanguageModelsOff() async throws {
        try await withPage(
            [scene("One", letterScene, .withTooEarly)], filed: CabinetSearchSheetTests.records
        ) { page in
            var seen = Set<String>()
            func check(_ state: String) async throws {
                seen.formUnion(try await Self.checkEveryTextView(in: page.window, state))
            }

            _ = try await page.showNotes()
            try await check("the Notes tab")
            page.preferences.showRightPanelTab(.comments)
            await eventually { page.card(noted) != nil }
            try #require(page.card(noted) != nil, "precondition: the comment's card shows")
            try await check("the Comments tab")
            page.preferences.showRightPanelTab(.tags)
            await eventually { page.card(noted) == nil }
            try #require(page.card(noted) == nil, "precondition: the Comments tab has gone")
            try await check("the Tags tab")

            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            page.page.performFindPanelAction(item)
            await eventually { (try? page.desk.findField) != nil }
            try #require(try page.desk.findField != nil, "precondition: the find bar shows")
            try await check("the find bar")

            let sheets: [(WindowMode, String)] = [
                (.scenes, ScenesWording.filterPlaceholder), (.search, SearchWording.placeholder),
                (.fileCabinet, FileCabinetWording.searchPlaceholder),
            ]
            for (mode, placeholder) in sheets {
                page.modes.mode = mode
                @MainActor func field() -> NSTextField? {
                    subviewTree(of: page.window.contentView).lazy.compactMap { $0 as? NSTextField }.first {
                        $0.placeholderString == placeholder && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor
                    }
                }
                await eventually { field() != nil }
                try #require(field() != nil, "precondition: the \(mode) sheet's field shows")
                try await check("the \(mode) sheet")
                page.modes.mode = .page
                await eventually { page.title.isEnabled }
            }

            page.filing.begin()
            await eventually { page.window.attachedSheet != nil }
            try #require(page.window.attachedSheet != nil, "precondition: File a Copy's dialog shows")
            try await check("File a Copy")
            page.filing.cancel()
            await eventually { page.window.attachedSheet == nil }

            let expected: Set<String> = [
                "page", "notes", "comment card", WindowWording.untitledScene,
                CommentWording.searchPlaceholder, "find bar", ScenesWording.filterPlaceholder,
                SearchWording.placeholder, FileCabinetWording.searchPlaceholder, "File a Copy's tags",
                "File a Copy's note",
            ]
            #expect(expected.subtracting(seen).isEmpty, "precondition: every surface was reached")
        }
    }

    /// AppKit adds Writing Tools to the Edit menu; Scene It takes it out, and again if it's added
    /// back.
    @Test func theMenusOfferNoWritingTools() async throws {
        let main = try #require(NSApp.mainMenu)
        await eventually { !Self.items(of: main).contains(where: LanguageModelsOff.offersWritingTools) }
        #expect(!Self.items(of: main).contains(where: LanguageModelsOff.offersWritingTools))
        #expect(!Self.items(of: main).contains { $0.title.localizedCaseInsensitiveContains("Writing Tools") })

        let edit = try #require(main.items.lazy.compactMap(\.submenu).first { $0.title == "Edit" })
        let added = NSMenuItem.writingToolsItems
        try #require(
            added.contains(where: LanguageModelsOff.offersWritingTools), "precondition: AppKit's items")
        edit.addItem(.separator())
        for item in added { edit.addItem(item) }
        await eventually { !Self.items(of: main).contains(where: LanguageModelsOff.offersWritingTools) }
        #expect(
            !Self.items(of: main).contains(where: LanguageModelsOff.offersWritingTools),
            "added back, taken out")
        #expect(edit.items.last?.isSeparatorItem == false, "with its separator")
    }

    @Test func takingWritingToolsOutLeavesNoStraySeparator() throws {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        for item in NSMenuItem.writingToolsItems { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        try #require(menu.items.contains(where: LanguageModelsOff.offersWritingTools), "precondition")
        LanguageModelsOff.removeWritingTools(from: menu)
        #expect(menu.items.map(\.title) == ["Copy", "", "Paste"])
        #expect(menu.items[1].isSeparatorItem)
    }

    /// Scene It's own editors hold both off whatever sets them.
    @Test func anEditorCantTurnThemBackOn() {
        let view = KeyboardTextView(editability: { .editable })
        view.writingToolsBehavior = .complete
        view.inlinePredictionType = .yes
        view.isAutomaticTextCompletionEnabled = true
        #expect(LanguageModelsOff.areOff(in: view))
    }

    /// Checks every text view in `window` and its sheet, and the editor of every field that
    /// takes typing; returns the names of what it checked.
    private static func checkEveryTextView(in window: NSWindow, _ state: String) async throws -> Set<String> {
        var checked = Set<String>()
        for window in [window, window.attachedSheet].compactMap(\.self) {
            let views = subviewTree(of: window.contentView).filter { !$0.isHiddenOrHasHiddenAncestor }
            for case let text as NSTextView in views where !text.isFieldEditor {
                #expect(LanguageModelsOff.areOff(in: text), "\(state): \(type(of: text))")
                checked.insert(name(of: text))
            }
            for case let field as NSTextField in views where field.isEditable && field.isEnabled {
                try #require(window.makeFirstResponder(field), "\(state): \(name(of: field)) takes the focus")
                let editor = try #require(
                    field.currentEditor() as? NSTextView, "\(state): \(name(of: field))")
                #expect(LanguageModelsOff.areOff(in: editor), "\(state): \(name(of: field))'s editor")
                try await Task.sleep(for: .milliseconds(50))
                #expect(
                    LanguageModelsOff.areOff(in: editor), "\(state): \(name(of: field))'s editor, updated")
                checked.insert(name(of: field))
                window.makeFirstResponder(nil)
            }
        }
        return checked
    }

    private static func name(of view: NSView) -> String {
        switch view {
        case is ManuscriptTextView: "page"
        case is CommentTextView: "comment card"
        case is SceneTextView: "notes"
        case is AdmittingTextView where view.window?.sheetParent != nil: "File a Copy's note"
        case is AdmittingTextField where view.window?.sheetParent != nil: "File a Copy's tags"
        case is NSSearchField: "find bar"
        case let field as NSTextField: field.placeholderString ?? "\(type(of: field))"
        default: "\(type(of: view))"
        }
    }

    private static func items(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
    }
}
