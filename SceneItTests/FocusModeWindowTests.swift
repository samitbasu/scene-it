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

/// Letters typed as the window gets them, one key at a time, into what has the focus.
@MainActor
private func type(_ text: String, in window: NSWindow) throws {
    for character in text {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: String(character),
                charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0))
        window.sendEvent(event)
    }
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
        await eventually { (try? desk.findFieldRoutesKeys) == true }
        try #require(
            try desk.findFieldRoutesKeys, "precondition: the find bar's field asks the window's keys")
        return try #require(try desk.findField)
    }

    /// Whether the Search sheet holds the focus: its own focus view, or its field. (SwiftUI
    /// focuses the field a turn after the sheet opens, and under load sometimes not at all; an
    /// Esc reaches the resolver either way.)
    var searchSheetHasTheFocus: Bool {
        switch focused {
        case is UndoFocusView: true
        case let field as NSTextField: field.placeholderString == SearchWording.placeholder
        default: false
        }
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
    /// window's: `focusModeHidesTheAppWindowsToolbarAndLeavingBringsItBack`.)
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

    @Test func escWithASheetOpenClosesTheSheetThenFocusMode() async throws {
        try await withPage([ferry]) { harness in
            harness.focusPage(at: 4)
            harness.chrome.set(.on)
            harness.modes.mode = .search
            await eventually { harness.searchSheetHasTheFocus }
            try #require(harness.searchSheetHasTheFocus, "precondition: the Search sheet has the focus")
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
            try #require(filing.draft != nil, "precondition: its draft")
            #expect(keys.escapeContext.dialog == .editing)

            try press(.escape, in: dialog)
            #expect(filing.draft == nil, "one Esc cancels the dialog")
            #expect(
                keys.lastEscape?.result == .close(.dialog), "through the resolver, not SwiftUI's dismissal")
            #expect(keys.lastEscape?.entrance != .focusedView, "by the dialog's own Esc")
            #expect(harness.chrome.focusMode == .on, "and only the dialog")
        }
    }

    /// The model is the only authority over the dialog: if its sheet ends behind SwiftUI's back,
    /// the draft stays, and File a Copy… shows the same draft again.
    @Test func aDialogEndedBehindTheModelsBackKeepsItsDraft() async throws {
        try await withPage([ferry]) { harness in
            let filing = try harness.keys.filing
            filing.begin()
            filing.draft?.note = "Keep me"
            let typed = try #require(filing.draft)
            await eventually { harness.window.attachedSheet != nil }
            let sheet = try #require(harness.window.attachedSheet, "precondition: the dialog is up")
            #expect(!filing.canBegin(in: harness.store), "precondition: File a Copy… is off while it shows")

            harness.window.endSheet(sheet)
            #expect(harness.window.attachedSheet == nil, "precondition: the sheet ended")
            #expect(filing.draft == typed, "the draft stays")
            // SwiftUI shows the sheet again itself, the model still saying it's up; if it didn't,
            // File a Copy… would be offered, and would bring it back.
            await eventually { harness.window.attachedSheet != nil || filing.canBegin(in: harness.store) }
            // Which way it came back; the backstop is pinned down in
            // `aDraftWhoseSheetWentIsOutOfEscsReachAndFileACopyBringsItBack`.
            var path = "SwiftUI showed it again"
            if harness.window.attachedSheet == nil {
                path = "File a Copy… showed it again"
                #expect(filing.canBegin(in: harness.store), "File a Copy… is offered, to bring it back")
                filing.begin()
                await eventually { harness.window.attachedSheet != nil }
            }
            #expect(harness.window.attachedSheet != nil, "the dialog is back (\(path))")
            #expect(filing.draft == typed, "with the same draft")
            await eventually { !filing.canBegin(in: harness.store) }
            #expect(!filing.canBegin(in: harness.store), "File a Copy… is off again while it shows")
            filing.cancel()
        }
    }

    /// The backstop, driven directly: a draft whose window has no sheet is out of Esc's reach (an
    /// Esc meant for the page closes what's on the page), and File a Copy… shows it again.
    @Test func aDraftWhoseSheetWentIsOutOfEscsReachAndFileACopyBringsItBack() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            let filing = FilingFlow(book: book)
            let chrome = WindowChrome()
            let keys = WindowKeys(chrome: chrome, filing: filing, page: PageFocus(), mode: .constant(.page))
            let window = NSWindow(
                contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled],
                backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            filing.window = window
            filing.begin()
            filing.draft?.note = "Keep me"
            let typed = try #require(filing.draft)
            #expect(!filing.canBegin(in: books.store), "precondition: a draft, its dialog taken as up")

            filing.sheetsChanged()
            try #require(
                window.attachedSheet == nil && filing.presentationLost, "precondition: its sheet went")
            #expect(keys.escapeContext.dialog == nil, "the dialog isn't an Esc layer while it isn't shown")
            chrome.set(.on)
            #expect(keys.escape(from: .focusedView) == .handled)
            #expect(keys.lastEscape?.result == .close(.focusMode), "Esc leaves focus mode")
            #expect(filing.draft == typed, "and the draft stays")
            #expect(keys.escape(from: .focusedView) == .passedOn, "with nothing else up, Esc passes on")
            #expect(filing.draft == typed)

            #expect(filing.canBegin(in: books.store), "File a Copy… is offered")
            let before = filing.presentation
            filing.begin()
            #expect(filing.presentation != before, "and shows the dialog afresh")
            #expect(filing.draft == typed, "with the same draft")
            filing.cancel()
            #expect(await books.store.closeBook() == .left)
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
            #expect(keys.lastEscape?.result == .hold(.dialog), "the resolver holds")
            #expect(filing.draft == typed, "Esc keeps the dialog and what was typed")
            #expect(harness.window.attachedSheet === dialog, "the dialog stays up")
            #expect(harness.chrome.focusMode == .on, "and closes nothing under it")

            release.yield()
            release.finish()
            #expect(await confirming.value == .failed(.archiveNotAFolder))
            #expect(filing.draft == typed, "the failed filing still has the draft")
            #expect(filing.stage == .editing)
            #expect(harness.window.attachedSheet === dialog, "the dialog is still the one shown")
            try press(.escape, in: dialog)
            #expect(filing.draft == nil, "once it's editable again, one Esc cancels it")
            #expect(keys.lastEscape?.result == .close(.dialog), "the resolver closed it")
            #expect(keys.lastEscape?.entrance != .focusedView, "through the dialog's own Esc")
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
            #expect(harness.focused === harness.page, "and the page keeps the focus")
            #expect(harness.chrome.focusMode == .off)

            _ = try await harness.showFindBar()
            await eventually { (try? harness.desk.findField).map { harness.focused === $0 } == true }
            try #require(
                harness.focused === (try harness.desk.findField), "precondition: the field has the focus")
            try press(.escape, in: harness.window)
            await eventually { (try? harness.desk.findField) == nil }
            #expect(
                try harness.desk.findField == nil, "Esc in its field closes it, through the window's keys")
            await eventually { harness.focused === harness.page }
            #expect(harness.focused === harness.page, "the focus goes back to the page")
            #expect(harness.page.selectedRange() == NSRange(location: 4, length: 0), "its caret where it was")
        }
    }

    /// A sheet covers the find bar, so Esc closes the sheet and leaves the find bar. The Esc is
    /// pressed once the sheet holds the focus: its own focus view, or the Search field. (The
    /// moment before, with the window itself the first responder, is
    /// `escReachingTheWindowItselfStillCloses`.)
    @Test func escWithASheetOverTheFindBarClosesOnlyTheSheet() async throws {
        try await withPage([ferry]) { harness in
            _ = try await harness.showFindBar()
            harness.focusPage(at: 4)
            harness.modes.mode = .search
            await eventually { harness.searchSheetHasTheFocus }
            try #require(harness.searchSheetHasTheFocus, "precondition: the sheet has the focus")
            #expect(EscapeLayer.escape(in: try harness.keys.escapeContext) == .close(.sheet))

            try press(.escape, in: harness.window)
            #expect(harness.modes.mode == .page, "Esc closes the sheet")
            #expect(try harness.desk.findField != nil, "and not the find bar it covered")
        }
    }

    /// An Esc that reaches the window itself, with no view holding the focus, still closes what
    /// Esc closes: a sheet, then focus mode.
    @Test func escReachingTheWindowItselfStillCloses() async throws {
        try await withPage([ferry]) { harness in
            harness.focusPage(at: 4)
            harness.chrome.set(.on)
            harness.modes.mode = .search
            #expect(harness.window.makeFirstResponder(nil))
            try #require(
                harness.window.firstResponder === harness.window, "precondition: no view has the focus")
            let keys = try harness.keys
            try press(.escape, in: harness.window)
            #expect(harness.modes.mode == .page, "Esc closes the sheet")
            #expect(harness.chrome.focusMode == .on, "and only the sheet")
            #expect(keys.lastEscape?.entrance == .window, "the fallback took it, not the sheet's EscapeKey")
            #expect(keys.lastEscape?.result == .close(.sheet))

            #expect(harness.window.makeFirstResponder(nil))
            try #require(
                harness.window.firstResponder === harness.window, "precondition: no view has the focus")
            try press(.escape, in: harness.window)
            #expect(harness.chrome.focusMode == .off, "Esc leaves focus mode")
            #expect(keys.lastEscape?.entrance == .window)
            #expect(keys.lastEscape?.result == .close(.focusMode))

            #expect(harness.window.makeFirstResponder(nil))
            try press(.escape, in: harness.window)
            #expect(harness.modes.mode == .page, "with nothing to close, nothing changes")
            #expect(harness.chrome.focusMode == .off)
        }
    }

    /// Esc closing the find bar puts the focus back where it was, with its own selection: a field
    /// made first responder would otherwise select all its text.
    @Test func closingTheFindBarKeepsTheTitlesSelection() async throws {
        try await withPage([ferry]) { harness in
            _ = try await harness.showFindBar()
            #expect(harness.window.makeFirstResponder(harness.title))
            let editor = try #require(harness.title.currentEditor())
            editor.selectedRange = NSRange(location: 3, length: 2)
            try press(.escape, in: harness.window)
            await eventually { (try? harness.desk.findField) == nil }
            #expect(try harness.desk.findField == nil, "Esc in the title closes the find bar")
            #expect(harness.focused === harness.title, "the title keeps the focus")
            #expect(harness.title.currentEditor()?.selectedRange == NSRange(location: 3, length: 2))
        }
    }

    @Test func closingTheFindBarKeepsTheCommentsSearchFieldsText() async throws {
        try await withPage([ferry]) { harness in
            _ = try await harness.showFindBar()
            harness.focusPage(at: 4)
            try press(.tab, in: harness.window)
            let search = try #require(harness.focused as? NSTextField)
            try #require(
                search.placeholderString == CommentWording.searchPlaceholder, "precondition: the field")
            try type("tide", in: harness.window)
            await eventually { search.stringValue == "tide" || search.currentEditor()?.string == "tide" }
            let editor = try #require(search.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            try press(.escape, in: harness.window)
            await eventually { (try? harness.desk.findField) == nil }
            #expect(harness.focused === search, "the search field keeps the focus")
            #expect(search.currentEditor()?.selectedRange == NSRange(location: 2, length: 0), "and its caret")
            #expect(search.stringValue == "tide")
        }
    }

    @Test func closingTheFindBarKeepsTheNotesSelection() async throws {
        try await withPage([ferry]) { harness in
            harness.preferences.showRightPanelTab(.notes)
            defer { harness.preferences.showRightPanelTab(.comments) }
            let notes = try await harness.showNotes()
            _ = try await harness.showFindBar()
            harness.focusNotes(notes, at: 0)
            notes.insertText("Tide tables.", replacementRange: notes.selectedRange())
            notes.setSelectedRange(NSRange(location: 5, length: 6))
            try press(.escape, in: harness.window)
            await eventually { (try? harness.desk.findField) == nil }
            #expect(harness.focused === notes, "the notes keep the focus")
            #expect(notes.selectedRange() == NSRange(location: 5, length: 6), "and their selection")
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
            await eventually { harness.focused === harness.page }
            #expect(harness.focused === harness.page, "the focus goes back to the page")
            try press(.escape, in: harness.window)
            #expect(harness.chrome.focusMode == .off, "so the next Esc leaves focus mode")
        }
    }

    /// Esc in Comments' search field asks the window first: it closes the page's find bar, and
    /// with nothing to close, the field keeps the focus.
    @Test func escInTheCommentsSearchFieldAsksTheWindowFirst() async throws {
        try await withPage([ferry]) { harness in
            _ = try await harness.showFindBar()
            harness.focusPage(at: 4)
            try press(.tab, in: harness.window)
            let search = try #require(harness.focused as? NSTextField)
            try #require(
                search.placeholderString == CommentWording.searchPlaceholder, "precondition: the field")

            try press(.escape, in: harness.window)
            await eventually { (try? harness.desk.findField) == nil }
            #expect(try harness.desk.findField == nil, "Esc there closes the page's find bar")
            #expect(harness.focused === search, "and the search field keeps the focus")

            try press(.escape, in: harness.window)
            #expect(harness.focused === search, "with nothing to close, the field's own Esc applies")
            #expect(harness.modes.mode == .page)
            #expect(harness.chrome.focusMode == .off)
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
}

/// Every test that shows a palette goes here, to run one at a time: a palette is a transient
/// popover, and showing one closes any other in the app, so two tests showing palettes at once
/// close each other's.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct FocusModePaletteTests {
    @Test func escWithAPaletteOpenClosesOnlyThePalette() async throws {
        try await withPage([ferry]) { harness in
            await eventually { popoverWindow() == nil }
            harness.focusPage(at: 4)
            harness.chrome.set(.on)
            // SwiftUI drops a popover asked for while its anchor is still moving, so the palette
            // opens once focus mode's layout is done: the desk at the window's left edge.
            await eventually { (try? harness.deskFrame.minX) == 0 }
            let keys = try harness.keys
            let popover = try await open(.palette(.body, .textColor), with: keys)

            try press(.escape, in: popover)
            #expect(keys.popover == nil, "Esc closes the palette")
            #expect(harness.chrome.focusMode == .on, "and only the palette")
            await eventually { popoverWindow() == nil }
            #expect(popoverWindow() == nil, "the palette is gone")

            try press(.escape, in: harness.window)
            #expect(harness.chrome.focusMode == .off, "the next Esc leaves focus mode")
        }
    }

    /// A palette whose bar goes (the Notes tab's, as focus mode hides the panel) doesn't stay
    /// open in the window's keys, so it neither takes the next Esc nor opens again (M1).
    @Test func aPaletteWhoseBarGoesIsForgotten() async throws {
        try await withPage([ferry]) { harness in
            await eventually { popoverWindow() == nil }
            harness.preferences.showRightPanelTab(.notes)
            defer { harness.preferences.showRightPanelTab(.comments) }
            await eventually { harness.notesView?.window != nil }
            harness.focusPage(at: 4)
            let keys = try harness.keys
            _ = try await open(.palette(.notes, .highlight), with: keys)

            harness.chrome.set(.on)
            await eventually { keys.popover == nil }
            #expect(keys.popover == nil, "the hidden bar's palette is forgotten")
            await eventually { popoverWindow() == nil }

            try press(.escape, in: harness.window)
            #expect(harness.chrome.focusMode == .off, "so Esc leaves focus mode")
            try await settle(harness)
            #expect(keys.popover == nil, "and the palette doesn't open again with its bar")
            #expect(popoverWindow() == nil)
        }
    }
}

// MARK: Helpers

/// Opens `palette` as its ▾ button does, and returns its window. SwiftUI sometimes drops a
/// popover just asked for in an offscreen window, setting its `isPresented` back to false (which
/// clears `keys.popover`); then the press is made again, as the writer would click again.
@MainActor
private func open(_ palette: WindowPopover, with keys: WindowKeys) async throws -> NSWindow {
    for _ in 0..<10 {
        keys.popover = palette
        await eventually { popoverWindow() != nil || keys.popover == nil }
        if let window = popoverWindow() { return window }
    }
    return try #require(popoverWindow(), "precondition: the palette is showing")
}

/// SwiftUI's layout of a change, done.
@MainActor
private func settle(_ harness: PageHarness) async throws {
    try await Task.sleep(for: .milliseconds(300))
    harness.window.contentView?.layoutSubtreeIfNeeded()
}

@MainActor
private func popoverWindow() -> NSWindow? {
    NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
}
