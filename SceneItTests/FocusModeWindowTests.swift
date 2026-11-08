import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// A key as the window gets it from `NSApplication.sendEvent`: offered first as a key
/// equivalent, then, if nothing takes it, sent to the window for its first responder.
@MainActor
private func press(_ key: TestKey, in window: NSWindow) throws {
    let event = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode))
    if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
}

private enum TestKey {
    case escape, tab, shiftTab

    var characters: String {
        switch self {
        case .escape: "\u{1b}"
        case .tab: "\t"
        case .shiftTab: "\u{19}"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .escape: 53
        case .tab, .shiftTab: 48
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        self == .shiftTab ? [.shift] : []
    }
}

/// The page's scene: long enough to place a caret well inside it.
private let ferry = scene(
    "The ferry",
    [
        [Run("The ferry left at dawn, and Mara watched the harbor lights go out one by one behind her.")],
        [Run("Nobody met her at the landing.")],
    ])

extension PageHarness {
    var keys: WindowKeys {
        get throws { try #require(try desk.keys) }
    }

    /// The view the window's focus is in: a field's own view while its field editor has it.
    var focused: NSResponder? {
        switch window.firstResponder {
        case let editor as NSTextView where editor.isFieldEditor: editor.delegate as? NSView
        case let responder: responder
        }
    }

    func showFindBar() async throws -> NSSearchField {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        page.performFindPanelAction(item)
        await eventually { (try? desk.findField) != nil }
        return try #require(try desk.findField)
    }

    /// The desk's frame in the window: where the chrome around it leaves it.
    var deskFrame: NSRect {
        get throws { try desk.convert(desk.bounds, to: nil) }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct FocusModeWindowTests {
    /// Focus mode hides the rail, toolbar, panel and status bar, so the desk takes their room;
    /// leaving it gives each back exactly, the panel open or collapsed as it was.
    @Test(arguments: [PanelVisibility.open, .closed])
    func enteringAndLeavingRestoresTheChromeExactly(panel: PanelVisibility) async throws {
        try await withPage([ferry], toolbar: .bridged) { harness in
            harness.preferences.setRightPanel(panel)
            defer { harness.preferences.setRightPanel(.open) }
            let window = harness.window
            await eventually { window.toolbar?.isVisible == true }
            try await settle(harness)
            let before = try harness.deskFrame
            #expect(window.toolbar?.isVisible == true, "precondition: the toolbar shows")

            harness.chrome.set(.on)
            await eventually { window.toolbar?.isVisible != true }
            try await settle(harness)
            let focused = try harness.deskFrame
            #expect(window.toolbar?.isVisible != true, "the toolbar hides")
            #expect(focused.minX < before.minX, "the rail hides: the desk reaches the window's left")
            #expect(focused.minX == 0, "nothing is left of the desk")
            #expect(focused.maxX > before.maxX, "the panel, open or collapsed, hides")
            #expect(focused.maxX == window.contentLayoutRect.maxX, "nothing is right of the desk")
            #expect(focused.minY < before.minY, "the status bar hides")
            #expect(harness.preferences.rightPanel == panel, "focus mode changes no preference")

            harness.chrome.set(.off)
            await eventually { window.toolbar?.isVisible == true }
            try await settle(harness)
            #expect(try harness.deskFrame == before, "the chrome is back exactly as it was")
            #expect(harness.preferences.rightPanel == panel)
        }
    }

    @Test func thePageKeepsTheFocusAndItsCaretAcrossEnteringAndLeaving() async throws {
        try await withPage([ferry]) { harness in
            harness.focusPage(at: 17)
            harness.page.setSelectedRange(NSRange(location: 17, length: 4))
            #expect(harness.window.firstResponder === harness.page, "precondition: the page has the focus")

            harness.chrome.set(.on)
            try await settle(harness)
            #expect(harness.window.firstResponder === harness.page, "the page keeps the focus")
            #expect(harness.page.selectedRange() == NSRange(location: 17, length: 4), "and its selection")

            try press(.escape, in: harness.window)
            #expect(harness.chrome.focusMode == .off, "Esc leaves focus mode")
            try await settle(harness)
            #expect(harness.window.firstResponder === harness.page)
            #expect(harness.page.selectedRange() == NSRange(location: 17, length: 4))
        }
    }

    /// Focus mode hides the panel, so what had the focus there is gone: the page takes it, its
    /// caret where it was.
    @Test func enteringFromTheNotesGivesThePageTheFocus() async throws {
        try await withPage([ferry]) { harness in
            harness.preferences.showRightPanelTab(.notes)
            defer { harness.preferences.showRightPanelTab(.comments) }
            harness.page.setSelectedRange(NSRange(location: 9, length: 0))
            await eventually { harness.notesView?.window != nil }
            let notes = try #require(harness.notesView)
            #expect(harness.window.makeFirstResponder(notes))

            harness.chrome.set(.on)
            await eventually { harness.window.firstResponder === harness.page }
            #expect(harness.window.firstResponder === harness.page)
            #expect(harness.page.selectedRange() == NSRange(location: 9, length: 0))
        }
    }

    @Test func escWithAPaletteOpenClosesOnlyThePalette() async throws {
        try await withPage([ferry]) { harness in
            harness.focusPage(at: 4)
            harness.chrome.set(.on)
            let keys = try harness.keys
            let palette = WindowPopover.palette(.body, .textColor)
            keys.popover = palette
            await eventually { Self.popoverWindow() != nil }
            let popover = try #require(Self.popoverWindow(), "precondition: the palette is showing")

            try press(.escape, in: popover)
            #expect(keys.popover == nil, "Esc closes the palette")
            #expect(harness.chrome.focusMode == .on, "and only the palette")
            await eventually { Self.popoverWindow() == nil }
            #expect(Self.popoverWindow() == nil, "the palette is gone")

            try press(.escape, in: harness.window)
            #expect(harness.chrome.focusMode == .off, "the next Esc leaves focus mode")
        }
    }

    @Test func escWithASheetOpenClosesTheSheetThenFocusMode() async throws {
        try await withPage([ferry]) { harness in
            harness.focusPage(at: 4)
            harness.chrome.set(.on)
            harness.modes.mode = .search
            await eventually { harness.focused is NSTextField }
            #expect(harness.focused is NSTextField, "precondition: the Search sheet's field has the focus")
            #expect(harness.chrome.focusMode == .on, "a sheet opens over focus mode")

            try press(.escape, in: harness.window)
            #expect(harness.modes.mode == .page, "Esc closes the sheet")
            #expect(harness.chrome.focusMode == .on, "and only the sheet")
            await eventually { harness.window.firstResponder === harness.page }
            #expect(harness.window.firstResponder === harness.page, "the page has the focus again")

            try press(.escape, in: harness.window)
            #expect(harness.chrome.focusMode == .off, "the next Esc leaves focus mode")
        }
    }

    @Test func escWithFileACopysDialogUpCancelsTheDialogFirst() async throws {
        try await withPage([ferry]) { harness in
            harness.focusPage(at: 4)
            harness.chrome.set(.on)
            let keys = try harness.keys
            let filing = keys.filing
            filing.begin()
            await eventually { harness.window.attachedSheet != nil }
            let dialog = try #require(harness.window.attachedSheet, "precondition: the dialog is up")
            #expect(keys.escapeContext.dialog == .present)

            try press(.escape, in: dialog)
            #expect(filing.draft == nil, "Esc cancels the dialog")
            #expect(harness.chrome.focusMode == .on, "and only the dialog")
        }
    }

    @Test func escWithNothingToCloseLeavesTheWindowAsItIs() async throws {
        try await withPage([ferry]) { harness in
            harness.focusPage(at: 4)
            try press(.escape, in: harness.window)
            #expect(harness.chrome.focusMode == .off)
            #expect(harness.modes.mode == .page)
            #expect(harness.window.firstResponder === harness.page)
        }
    }

    /// Tab: the page, the panel's editor, the find bar's field, and round; Shift-Tab back.
    @Test func tabCyclesThePageThePanelAndTheSearchField() async throws {
        try await withPage([ferry]) { harness in
            harness.preferences.showRightPanelTab(.notes)
            defer { harness.preferences.showRightPanelTab(.comments) }
            await eventually { harness.notesView?.window != nil }
            let notes = try #require(harness.notesView)
            let find = try await harness.showFindBar()
            harness.focusPage(at: 4)
            #expect(harness.focused === harness.page, "precondition: the page has the focus")

            try press(.tab, in: harness.window)
            #expect(harness.focused === notes, "page → the panel's editor")
            try press(.tab, in: harness.window)
            #expect(harness.focused === find, "panel → the search field")
            try press(.tab, in: harness.window)
            #expect(harness.focused === harness.page, "search field → the page")
            #expect(harness.page.selectedRange() == NSRange(location: 4, length: 0), "its caret where it was")

            try press(.shiftTab, in: harness.window)
            #expect(harness.focused === find, "Shift-Tab: page → the search field")
            try press(.shiftTab, in: harness.window)
            #expect(harness.focused === notes, "search field → the panel")
            try press(.shiftTab, in: harness.window)
            #expect(harness.focused === harness.page, "panel → the page")
        }
    }

    /// With no editor in the panel's tab, Tab goes to its first control: Comments' search field.
    @Test func tabReachesTheCommentsSearchFieldAndLeavesIt() async throws {
        try await withPage([ferry]) { harness in
            try #require(harness.preferences.rightPanelTab == .comments, "precondition: the Comments tab")
            harness.focusPage(at: 4)

            try press(.tab, in: harness.window)
            await eventually {
                (harness.focused as? NSTextField)?.placeholderString == CommentWording.searchPlaceholder
            }
            let search = try #require(harness.focused as? NSTextField)
            #expect(
                search.placeholderString == CommentWording.searchPlaceholder, "page → Comments' search field")

            try press(.tab, in: harness.window)
            await eventually { harness.focused === harness.page }
            #expect(harness.focused === harness.page, "no find bar: the panel → the page")
        }
    }

    /// In focus mode the panel is hidden, so Tab skips it.
    @Test func tabInFocusModeSkipsTheHiddenPanel() async throws {
        try await withPage([ferry]) { harness in
            let find = try await harness.showFindBar()
            harness.focusPage(at: 4)
            harness.chrome.set(.on)
            try await settle(harness)

            try press(.tab, in: harness.window)
            #expect(harness.focused === find, "page → the search field")
            try press(.tab, in: harness.window)
            #expect(harness.focused === harness.page, "search field → the page")
            try press(.tab, in: harness.window)
            #expect(harness.focused === find)
        }
    }

    /// Recommended: focus mode stays on as another scene opens; the other rule leaves it.
    @Test(arguments: [SceneSwitchInFocusMode.staysInFocusMode, .leavesFocusMode])
    func openingAnotherSceneFollowsTheRule(rule: SceneSwitchInFocusMode) async throws {
        var rules = FocusModeRules.recommended
        rules.sceneSwitch = rule
        let other = scene("Arrival", [[Run("The island was smaller than she remembered.")]])
        try await withPage([ferry, other], chrome: WindowChrome(rules: rules)) { harness in
            harness.focusPage(at: 4)
            harness.chrome.set(.on)
            harness.book.select(other.id)
            await eventually { harness.storage.string.hasPrefix("The island") }
            try await settle(harness)
            #expect(harness.chrome.focusMode == (rule == .staysInFocusMode ? .on : .off))
        }
    }

    @Test func theViewMenuHasFocusModeOnCommandShiftReturn() throws {
        let item = try #require(menuItem(titled: WindowWording.focusMode, in: NSApp.mainMenu))
        #expect(item.keyEquivalent == "\r")
        #expect(
            item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [
                .command, .shift,
            ])
    }

    // MARK: Helpers

    /// SwiftUI's layout of a change, done.
    private func settle(_ harness: PageHarness) async throws {
        try await Task.sleep(for: .milliseconds(300))
        harness.window.contentView?.layoutSubtreeIfNeeded()
    }

    private static func popoverWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }
}
