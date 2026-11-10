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
    /// The book window's view tree with each right-panel tab and the find bar. Every field takes
    /// the focus, so its editor is the one it types with.
    @Test func everyTextViewBesideThePageHasThemOff() async throws {
        try await withBookWindow(reaching: [
            "page", "notes", "comment card", WindowWording.untitledScene, CommentWording.searchPlaceholder,
            TagWording.addPlaceholder, "find bar",
        ]) { page, check in
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
        }
    }

    /// Each sheet's field, and again after the text SwiftUI shows in it changes while it's edited.
    @Test func everySheetsFieldHasThemOff() async throws {
        try await withBookWindow(reaching: [
            ScenesWording.filterPlaceholder, SearchWording.placeholder, FileCabinetWording.searchPlaceholder,
        ]) { page, check in
            let sheets: [(WindowMode, String, @MainActor (String) -> Void)] = [
                (.scenes, ScenesWording.filterPlaceholder, { page.scenes.filter = $0 }),
                (.search, SearchWording.placeholder, { page.search.text = $0 }),
                (.fileCabinet, FileCabinetWording.searchPlaceholder, { page.cabinet.filter.words = $0 }),
            ]
            for (mode, placeholder, change) in sheets {
                page.modes.mode = mode
                @MainActor func field() -> NSTextField? {
                    subviewTree(of: page.window.contentView).lazy.compactMap { $0 as? NSTextField }.first {
                        $0.placeholderString == placeholder && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor
                    }
                }
                await eventually { field() != nil }
                let sheetField = try #require(field(), "precondition: the \(mode) sheet's field shows")
                try await check("the \(mode) sheet")
                #expect(page.window.makeFirstResponder(sheetField))
                let editor = try #require(sheetField.currentEditor() as? NSTextView)
                change("zz")
                await eventually { editor.string == "zz" }
                #expect(editor.string == "zz", "precondition: SwiftUI updated the field being edited")
                #expect(LanguageModelsOff.areOff(in: editor), "the \(mode) sheet's editor, after an update")
                page.window.makeFirstResponder(nil)
                change("")
                page.modes.mode = .page
                await eventually { page.title.isEnabled }
            }
        }
    }

    /// File a Copy's dialog and Export as SceneIt's chooser, each a sheet window of its own.
    @Test func everyDialogsTextViewHasThemOff() async throws {
        try await withBookWindow(reaching: ["File a Copy's tags", "File a Copy's note"]) { page, check in
            page.filing.begin()
            await eventually { page.window.attachedSheet != nil }
            try #require(page.window.attachedSheet != nil, "precondition: File a Copy's dialog shows")
            try await check("File a Copy")
            page.filing.cancel()
            await eventually { page.window.attachedSheet == nil }

            page.export.begin()
            await eventually { page.window.attachedSheet != nil }
            try #require(page.window.attachedSheet != nil, "precondition: Export as SceneIt's chooser shows")
            try await check("Export as SceneIt")
            page.export.cancel()
            await eventually { page.window.attachedSheet == nil }
        }
    }

    /// AppKit adds Writing Tools to the Edit menu; Scene It takes it out, and again if it's added
    /// back.
    @Test func theMenusOfferNoWritingTools() async throws {
        let main = try #require(NSApp.mainMenu)
        let topLevel = main.items.map(\.title)
        let edit = try #require(main.items.lazy.compactMap(\.submenu).first { $0.title == "Edit" })
        let editItems = edit.items.count
        #expect(!Self.items(of: main).contains(where: LanguageModelsOff.offersWritingTools))
        #expect(!Self.items(of: main).contains { $0.title.localizedCaseInsensitiveContains("Writing Tools") })

        edit.addItem(.separator())
        for item in NSMenuItem.writingToolsItems { edit.addItem(item) }
        try #require(
            Self.items(of: main).contains(where: LanguageModelsOff.offersWritingTools),
            "precondition: AppKit's Writing Tools items are in the Edit menu")
        await eventually { !Self.items(of: main).contains(where: LanguageModelsOff.offersWritingTools) }
        #expect(
            !Self.items(of: main).contains(where: LanguageModelsOff.offersWritingTools),
            "added back, taken out")
        #expect(edit.items.count == editItems, "with its separator, and nothing else")
        #expect(main.items.map(\.title) == topLevel, "every top-level menu is still there")
        #expect(edit.supermenu === main, "the Edit menu is still there")
    }

    /// A menu that only holds a Writing Tools item among others is never taken for one.
    @Test func aMenuWithOtherItemsIsntWritingTools() throws {
        let tools = try #require(NSMenuItem.writingToolsItems.first)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        let show = NSMenuItem(
            title: "Show Writing Tools", action: #selector(NSResponder.showWritingTools(_:)),
            keyEquivalent: "")
        edit.submenu?.addItem(show)
        #expect(!LanguageModelsOff.offersWritingTools(edit))
        #expect(LanguageModelsOff.offersWritingTools(show))
        #expect(LanguageModelsOff.offersWritingTools(tools), "precondition: AppKit's item is one")
        let main = NSMenu(title: "Main")
        main.addItem(edit)
        LanguageModelsOff.removeWritingTools(from: main)
        #expect(main.items == [edit])
        #expect(edit.submenu?.items.map(\.title) == ["Copy"])
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

    /// Any window in the app, not only the book window: a plain AppKit field, as an open or save
    /// panel has, types with an editor that has them off.
    @Test func aFieldInAnyWindowHasThemOff() async throws {
        let field = NSTextField(string: "words")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        window.setFrame(NSRect(x: -30000, y: -30000, width: 300, height: 80), display: false)
        window.orderFront(nil)
        defer { window.close() }
        window.update()
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(!(editor is KeyboardTextView), "precondition: the window's own field editor")
        #expect(LanguageModelsOff.areOff(in: editor))
    }

    /// ADR 0049 lists the open and save panels as system UI: their fields live in another
    /// process, out of Scene It's reach. If they ever come into the app's own windows, this
    /// fails, and the app-wide watch (`aFieldInAnyWindowHasThemOff`) then covers them.
    @Test func theOpenAndSavePanelsFieldsAreTheSystems() {
        for panel in [NSSavePanel(), NSOpenPanel()] {
            let views = subviewTree(of: panel.contentView)
            #expect(
                views.contains { NSStringFromClass(type(of: $0)).contains("Remote") },
                "precondition: \(type(of: panel)) shows another process's view")
            #expect(!views.contains { $0 is NSText || $0 is NSTextField }, "\(type(of: panel))")
        }
    }

    /// Scene It's own editors hold both off whatever sets them.
    @Test func anEditorCantTurnThemBackOn() {
        let view = KeyboardTextView(editability: { .editable })
        view.writingToolsBehavior = .complete
        view.inlinePredictionType = .yes
        view.isAutomaticTextCompletionEnabled = true
        #expect(LanguageModelsOff.areOff(in: view))
    }

    /// The book window over a commented scene with filed copies; `body` checks it in each state
    /// it reaches (`check`), and between them they must check each of `surfaces`.
    private func withBookWindow(
        reaching surfaces: Set<String>,
        _ body: (PageHarness, _ check: (String) async throws -> Void) async throws -> Void
    ) async throws {
        try await withPage(
            [scene("One", letterScene, .withTooEarly)], filed: CabinetSearchSheetTests.records
        ) { page in
            var seen = Set<String>()
            try await body(page) { state in
                seen.formUnion(try await Self.checkEveryTextView(in: page.window, state))
            }
            #expect(surfaces.subtracting(seen).isEmpty, "precondition: every surface was reached")
        }
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
