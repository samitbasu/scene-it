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
    /// Focus mode hides the rail, panel and status bar, so the desk takes their room; leaving it
    /// gives each back exactly, the panel open or collapsed as it was. (The toolbar is the app
    /// window's: `FocusModeInTheAppsWindowTests`.)
    @Test(arguments: [PanelVisibility.open, .closed])
    func enteringAndLeavingRestoresTheChromeExactly(panel: PanelVisibility) async throws {
        try await withPage([ferry]) { harness in
            harness.preferences.setRightPanel(panel)
            defer { harness.preferences.setRightPanel(.open) }
            let window = harness.window
            try await settle(harness)
            let before = try harness.deskFrame

            harness.chrome.set(.on)
            try await settle(harness)
            let focused = try harness.deskFrame
            #expect(focused.minX < before.minX, "the rail hides: the desk reaches the window's left")
            #expect(focused.minX == 0, "nothing is left of the desk")
            #expect(focused.maxX > before.maxX, "the panel, open or collapsed, hides")
            #expect(focused.maxX == window.contentLayoutRect.maxX, "nothing is right of the desk")
            #expect(focused.minY < before.minY, "the status bar hides")
            #expect(harness.preferences.rightPanel == panel, "focus mode changes no preference")

            harness.chrome.set(.off)
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
            #expect(keys.escapeContext.dialog == .editing)

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

    @Test func focusModeStaysOnAsAnotherSceneOpens() async throws {
        let other = scene("Arrival", [[Run("The island was smaller than she remembered.")]])
        try await withPage([ferry, other]) { harness in
            harness.focusPage(at: 4)
            harness.chrome.set(.on)
            harness.book.select(other.id)
            await eventually { harness.storage.string.hasPrefix("The island") }
            try await settle(harness)
            #expect(harness.chrome.focusMode == .on)
        }
    }

    /// While File a Copy files, Esc closes nothing: the draft stays, so a filing that fails
    /// still has what the writer typed (H1).
    @Test func escWhileTheDialogFilesKeepsItAndItsDraft() async throws {
        try await withPage([ferry]) { harness in
            harness.focusPage(at: 4)
            harness.chrome.set(.on)
            let keys = try harness.keys
            let filing = keys.filing
            filing.begin()
            filing.draft?.note = "Keep me"
            let typed = filing.draft
            await eventually { harness.window.attachedSheet != nil }
            let dialog = try #require(harness.window.attachedSheet, "precondition: the dialog is up")
            let (held, release) = AsyncStream<Void>.makeStream()
            let confirming = Task {
                await filing.confirm { _ in
                    for await _ in held { break }
                    return .failed(.archiveNotAFolder)
                }
            }
            await eventually { filing.stage == .filing }
            #expect(keys.escapeContext.dialog == .filing, "precondition: the copy is being filed")

            try press(.escape, in: dialog)
            try press(.escape, in: harness.window)
            #expect(filing.draft == typed, "Esc keeps the dialog and what was typed")
            #expect(harness.chrome.focusMode == .on, "and closes nothing under it")

            release.yield()
            release.finish()
            #expect(await confirming.value == .failed(.archiveNotAFolder))
            #expect(filing.draft == typed, "the failed filing still has the draft")
            #expect(filing.stage == .editing)
            try press(.escape, in: dialog)
            #expect(filing.draft == nil, "once it's editable again, Esc cancels it")
        }
    }

    /// A palette whose bar goes (the Notes tab's, as focus mode hides the panel) doesn't stay
    /// open in the window's keys, so it neither takes the next Esc nor opens again (M1).
    @Test func aPaletteWhoseBarGoesIsForgotten() async throws {
        try await withPage([ferry]) { harness in
            harness.preferences.showRightPanelTab(.notes)
            defer { harness.preferences.showRightPanelTab(.comments) }
            await eventually { harness.notesView?.window != nil }
            harness.focusPage(at: 4)
            let keys = try harness.keys
            keys.popover = .palette(.notes, .highlight)
            await eventually { Self.popoverWindow() != nil }
            try #require(Self.popoverWindow() != nil, "precondition: the notes' palette is showing")

            harness.chrome.set(.on)
            await eventually { keys.popover == nil }
            #expect(keys.popover == nil, "the hidden bar's palette is forgotten")
            await eventually { Self.popoverWindow() == nil }

            try press(.escape, in: harness.window)
            #expect(harness.chrome.focusMode == .off, "so Esc leaves focus mode")
            try await settle(harness)
            #expect(keys.popover == nil, "and the palette doesn't open again with its bar")
            #expect(Self.popoverWindow() == nil)
        }
    }

    /// Under a sheet, Tab reaches nothing the sheet covers: not the page, its title or its find
    /// bar (M3).
    @Test func tabUnderASheetReachesNothingItCovers() async throws {
        try await withPage([ferry]) { harness in
            let find = try await harness.showFindBar()
            harness.focusPage(at: 4)
            harness.modes.mode = .scenes
            await eventually { harness.window.firstResponder is UndoFocusView }
            try #require(
                harness.window.firstResponder is UndoFocusView, "precondition: the sheet has the focus")
            let covered: [NSResponder] = [harness.page, harness.title, find]
            let desk = try harness.desk
            for key in [TestKey.tab, .shiftTab, .tab] {
                try press(key, in: harness.window)
                let focused = try #require(harness.focused)
                #expect(!covered.contains { $0 === focused }, "\(key): the focus stays out of the page")
                #expect((focused as? NSView)?.isDescendant(of: desk) != true, "\(key): nor on the desk")
            }
            #expect(harness.window.firstResponder is UndoFocusView, "the sheet keeps the focus")
        }
    }

    // MARK: Esc and the find bar (M4)

    @Test func escClosesTheFindBarAloneFromThePageOrItsField() async throws {
        try await withPage([ferry]) { harness in
            _ = try await harness.showFindBar()
            harness.focusPage(at: 4)
            try press(.escape, in: harness.window)
            await eventually { (try? harness.desk.findField) == nil }
            #expect(try harness.desk.findField == nil, "Esc in the page closes the find bar")
            #expect(harness.chrome.focusMode == .off)

            _ = try await harness.showFindBar()
            await eventually { (try? harness.desk.findField).map { harness.focused === $0 } == true }
            try #require(
                harness.focused === (try harness.desk.findField), "precondition: the field has the focus")
            try press(.escape, in: harness.window)
            await eventually { (try? harness.desk.findField) == nil }
            #expect(
                try harness.desk.findField == nil, "Esc in its field closes it, through the window's keys")
        }
    }

    @Test func escWithASheetOverTheFindBarClosesOnlyTheSheet() async throws {
        try await withPage([ferry]) { harness in
            _ = try await harness.showFindBar()
            harness.focusPage(at: 4)
            harness.modes.mode = .search
            let desk = try harness.desk
            await eventually {
                harness.focused != nil && harness.focused !== harness.page
                    && (harness.focused as? NSView)?.isDescendant(of: desk) != true
            }
            try #require(harness.focused !== harness.page, "precondition: the sheet has the focus")
            try press(.escape, in: harness.window)
            #expect(harness.modes.mode == .page, "Esc closes the sheet")
            try await settle(harness)
            #expect(try harness.desk.findField != nil, "and not the find bar it covered")
        }
    }

    @Test func inFocusModeEscClosesTheFindBarThenLeaves() async throws {
        try await withPage([ferry]) { harness in
            let find = try await harness.showFindBar()
            #expect(harness.window.makeFirstResponder(find))
            harness.chrome.set(.on)
            try await settle(harness)
            #expect(harness.focused === find, "entering focus mode leaves the focus in the find field (L5)")

            try press(.escape, in: harness.window)
            await eventually { (try? harness.desk.findField) == nil }
            #expect(try harness.desk.findField == nil, "the first Esc closes the find bar")
            #expect(harness.chrome.focusMode == .on)
            harness.focusPage(at: 4)
            try press(.escape, in: harness.window)
            #expect(harness.chrome.focusMode == .off, "the next leaves focus mode")
        }
    }

    /// The find bar's field still finds after its delegate is stood in for (L2).
    @Test func theFindFieldStillFinds() async throws {
        try await withPage([ferry]) { harness in
            let find = try await harness.showFindBar()
            harness.focusPage(at: 0)
            #expect(try harness.desk.focusFindField(), "precondition: the field takes the focus")
            let editor = try #require(harness.window.firstResponder as? NSTextView)
            try #require(editor.isFieldEditor && editor.delegate === find)
            editor.insertText("harbor", replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            let match = (harness.storage.string as NSString).range(of: "harbor")
            await eventually { harness.page.selectedRange() == match }
            #expect(harness.page.selectedRange() == match, "Return finds what was typed")
        }
    }

    /// Shift-Tab out of Comments' search field goes back to the page (L3).
    @Test func shiftTabLeavesTheCommentsSearchFieldBackwards() async throws {
        try await withPage([ferry]) { harness in
            harness.focusPage(at: 4)
            try press(.tab, in: harness.window)
            await eventually {
                (harness.focused as? NSTextField)?.placeholderString == CommentWording.searchPlaceholder
            }
            try press(.shiftTab, in: harness.window)
            await eventually { harness.focused === harness.page }
            #expect(harness.focused === harness.page)
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
