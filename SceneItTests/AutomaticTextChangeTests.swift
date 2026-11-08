import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// #127: the system's automatic changes to typed text start off, the macOS way: the app
/// registers them off at launch, every editor takes what the defaults say, and the writer turns
/// each on or off from the menus. Nothing here sends a toggle action or writes the app's saved
/// defaults: AppKit saves a menu toggle there.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct AutomaticTextChangeTests {
    @Test func theStartingValuesAreRegisteredOff() {
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        for key in AutomaticTextChanges.startingValues.keys.sorted() {
            #expect(registered[key] as? Bool == false, "\(key)")
        }
    }

    /// A key no saved domain sets (neither the app's, where a menu toggle goes, nor System
    /// Settings') is off, because the registration says so; and AppKit reads it.
    @Test func whatTheWriterHasntChosenStartsOff() {
        let undecided = Self.keysNoSavedDomainSets()
        #expect(
            undecided.contains("NSAutomaticSpellingCorrectionEnabled"),
            "precondition: spelling correction is left to the registration on this Mac")
        for key in undecided {
            #expect(UserDefaults.standard.object(forKey: key) as? Bool == false, "\(key)")
        }
        for (key, value) in Self.whatAppKitReads() where undecided.contains(key) {
            #expect(value == false, "AppKit reads \(key) as off")
        }
    }

    /// Every editor takes the automatic changes as the defaults say, and none sets them itself.
    @Test func everyEditorTakesWhatTheDefaultsSay() async throws {
        let expected = Self.whatTheDefaultsSay()
        try await withEditors { editors in
            for (name, editor) in editors {
                #expect(Self.switches(of: editor) == expected, "\(name)")
            }
        }
        try await withFixField { _, editor, _, _ in
            #expect(Self.switches(of: editor) == expected, "the Errors tab's fix")
        }
    }

    /// What a menu toggle does to an editor stays done: nothing turns it back.
    @Test func anEditorTurnedOnStaysOn() async throws {
        try await withEditors { editors in
            for (name, editor) in editors {
                let was = editor.isAutomaticSpellingCorrectionEnabled
                editor.isAutomaticSpellingCorrectionEnabled = !was
                editor.isAutomaticTextReplacementEnabled = true
                try await Task.sleep(for: .milliseconds(50))
                #expect(editor.isAutomaticSpellingCorrectionEnabled == !was, "\(name)")
                #expect(editor.isAutomaticTextReplacementEnabled, "\(name)")
                editor.isAutomaticSpellingCorrectionEnabled = was
            }
        }
    }

    /// Smart links only mark text for display: a detected link never reaches the scene or the
    /// saved book, which hold the typed text alone.
    @Test func aLinkDetectedOnThePageStaysOutOfTheBook() async throws {
        try await withPage([scene("One", [[Run("Start.")]])]) { page in
            page.page.isAutomaticLinkDetectionEnabled = true
            page.focusPage(at: 6)
            page.page.insertText(" See www.example.com today.", replacementRange: page.page.selectedRange())
            page.page.checkTextInDocument(nil)
            let storage = page.storage
            var linked = false
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) {
                value, _, _ in
                if value != nil { linked = true }
            }
            #expect(linked, "precondition: the page shows the address as a link")
            let typed: [Paragraph] = [[Run("Start. See www.example.com today.")]]
            #expect(page.body() == typed)
            await eventually { page.book.status == .saved }
            let saved = try bookOnDisk(page.url)
            #expect(saved.scenes.first?.body == typed)
        }
    }

    /// The menus are the standard ones: the writer switches these themselves.
    @Test func theEditMenuOffersTheToggles() throws {
        let titles = shownItems(of: try editMenu()).map(\.title)
        #expect(titles.contains("Correct Spelling Automatically"))
        #expect(titles.contains("Substitutions"))
        #expect(titles.contains("Text Replacement"))
        #expect(titles.contains("Check Spelling While Typing"))
    }

    @Test func everyEditorsContextMenuOffersTheToggles() async throws {
        try await withEditors { editors in
            for (name, editor) in editors {
                let menu = try #require(
                    editor.menu(for: try rightClick(on: editor)), "\(name)'s context menu")
                let titles = shownItems(of: menu).map(\.title)
                #expect(titles.contains("Correct Spelling Automatically"), "\(name)")
                #expect(titles.contains("Substitutions"), "\(name)")
            }
        }
    }

    /// The keys AppKit reads that neither the app's saved defaults nor System Settings set.
    static func keysNoSavedDomainSets() -> Set<String> {
        let defaults = UserDefaults.standard
        let saved = [
            defaults.persistentDomain(forName: UserDefaults.globalDomain) ?? [:],
            defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:],
        ]
        return Set(
            AutomaticTextChanges.startingValues.keys.filter { key in !saved.contains { $0[key] != nil } })
    }

    /// What AppKit takes from each key: a fresh text view's switch, or the spelling checker's.
    static func whatAppKitReads() -> [String: Bool] {
        let view = NSTextView(usingTextLayoutManager: true)
        return switches(of: view).merging([
            "NSAutomaticTextCompletionEnabled": NSSpellChecker.isAutomaticTextCompletionEnabled,
            "NSAutomaticInlinePredictionEnabled": NSSpellChecker.isAutomaticInlinePredictionEnabled,
            "NSAutomaticCapitalizationEnabled": NSSpellChecker.isAutomaticCapitalizationEnabled,
            "NSAutomaticPeriodSubstitutionEnabled": NSSpellChecker.isAutomaticPeriodSubstitutionEnabled,
        ]) { view, _ in view }
    }

    /// A text view's own switches, by the key each starts from, and link and data detection,
    /// which have no key and start off.
    static func switches(of view: NSTextView) -> [String: Bool] {
        [
            "NSAutomaticSpellingCorrectionEnabled": view.isAutomaticSpellingCorrectionEnabled,
            "NSAutomaticQuoteSubstitutionEnabled": view.isAutomaticQuoteSubstitutionEnabled,
            "NSAutomaticDashSubstitutionEnabled": view.isAutomaticDashSubstitutionEnabled,
            "link detection": view.isAutomaticLinkDetectionEnabled,
            "data detection": view.isAutomaticDataDetectionEnabled,
        ]
    }

    /// What `switches(of:)` should read, by the defaults.
    static func whatTheDefaultsSay() -> [String: Bool] {
        let defaults = UserDefaults.standard
        return [
            "NSAutomaticSpellingCorrectionEnabled": defaults.bool(
                forKey: "NSAutomaticSpellingCorrectionEnabled"),
            "NSAutomaticQuoteSubstitutionEnabled": defaults.bool(
                forKey: "NSAutomaticQuoteSubstitutionEnabled"),
            "NSAutomaticDashSubstitutionEnabled": defaults.bool(forKey: "NSAutomaticDashSubstitutionEnabled"),
            "link detection": false, "data detection": false,
        ]
    }

    /// The Errors tab's fix is a line of the manuscript, so it's edited as the manuscript is.
    @Test func theErrorsTabsFixIsEditedAsTheManuscriptIs() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            _ = try BookPackage.create(at: url, title: "Novel")
            try Data(Self.damaged.utf8).write(to: url.appending(path: "book.md"))
            let books = BookController(role: .testHost)
            _ = await books.store.open(url)
            let book = try #require(books.store.current)
            #expect(await books.store.makeEditable() == .editable)
            try #require(book.book.errorCount == 1, "precondition: the broken comment")
            let window = await hostOffscreen(
                ErrorsTab(book: book), size: CGSize(width: WindowMetrics.panelWidth, height: 700)
            ) { window in
                Self.buttons(in: window).count == 3 && Self.buttons(in: window).allSatisfy(\.isEnabled)
            }
            defer { window.close() }
            try #require(Self.buttons(in: window).count == 3, "precondition: Copy, Fix and Delete")
            Self.buttons(in: window)[1].performClick(nil)
            await eventually { subviewTree(of: window.contentView).contains { $0 is AdmittingTextField } }
            let field = try #require(
                subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first)
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? AdmittingTextView, "the fix's own editor")
            #expect(editor.inputContext == nil)
            #expect(
                editor.isAutomaticSpellingCorrectionEnabled
                    == UserDefaults.standard.bool(forKey: "NSAutomaticSpellingCorrectionEnabled"))
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText(
                Self.brokenComment.replacing("mauve", with: "purplé"),
                replacementRange: editor.selectedRange())
            #expect(editor.string == Self.brokenComment.replacing("mauve", with: "purple"), "held to ASCII")
            await eventually { field.frame.height > 2 * 22 }
            #expect(field.frame.height > 2 * 22, "the long line wraps, and the field grows to show it")
            #expect(await books.store.closeBook() == .left)
        }
    }

    /// What's typed in a fix's field reaches the row's draft, which Apply applies, across
    /// SwiftUI updating the field between keystrokes.
    @Test func aFixsFieldPassesWhatsTypedToTheDraft() async throws {
        try await withFixField { field, editor, draft, window in
            editor.setSelectedRange(NSRange(location: 7, length: 5))
            editor.insertText("purp", replacementRange: editor.selectedRange())
            #expect(draft.text == "- c1 | purp")
            await nextUpdate(of: editor)
            editor.insertText("le", replacementRange: editor.selectedRange())
            #expect(editor.string == "- c1 | purple")
            #expect(editor.selectedRange() == NSRange(location: 13, length: 0))
            #expect(draft.text == "- c1 | purple")
        }
    }

    /// While the writer edits a fix, a change to the draft from elsewhere doesn't replace what
    /// they're typing or move the caret.
    @Test func aFixBeingEditedKeepsItsTypingWhenTheDraftChangesElsewhere() async throws {
        try await withFixField { field, editor, draft, window in
            editor.setSelectedRange(NSRange(location: 7, length: 5))
            editor.insertText("purp", replacementRange: editor.selectedRange())
            draft.text = "- c1 | changed elsewhere"
            await nextUpdate(of: editor)
            #expect(editor.string == "- c1 | purp")
            #expect(editor.selectedRange() == NSRange(location: 11, length: 0))
        }
    }

    /// Typing in a fix is undone in the fix, never through the window's history, where the
    /// manuscript's edits are; and taking the fix away mid-edit (Apply, Cancel) ends the editing.
    @Test func aFixsTypingHasItsOwnHistory() async throws {
        try await withFixField { field, editor, draft, window in
            editor.insertText("x", replacementRange: NSRange(location: 0, length: 0))
            #expect(editor.undoManager?.canUndo == true, "precondition: the typing can be undone")
            #expect(editor.undoManager !== window.undoManager)
            #expect(window.undoManager?.canUndo != true, "the window's history holds nothing of it")
            #expect(window.firstResponder === editor, "precondition: the fix is being edited")
            draft.shown = false
            await eventually { field.window == nil }
            #expect(field.currentEditor() == nil, "the editing ended")
            #expect(window.firstResponder !== editor, "the window doesn't keep the fix's editor")
            #expect(window.undoManager?.canUndo != true)
        }
    }
    static let brokenComment = "- c1 | mauve | 2026-10-31T20:40:00-07:00 | c12-18 | \"letter\" | Too early?"

    static let damaged = """
        ---
        title: Novel
        format: 2
        ---

        ## The ferry
        id: ferry
        modified: 2026-10-31T20:40:00-07:00

        He read the letter twice.

        ### Comments
        \(brokenComment)

        """

    /// The window's shown buttons, left to right, then top to bottom.
    private static func buttons(in window: NSWindow) -> [NSButton] {
        subviewTree(of: window.contentView).compactMap { $0 as? NSButton }.filter {
            !$0.isHiddenOrHasHiddenAncestor
        }
        .sorted {
            let (a, b) = ($0.convert($0.bounds, to: nil), $1.convert($1.bounds, to: nil))
            return (-a.minY, a.minX) < (-b.minY, b.minX)
        }
    }
    private func editMenu() throws -> NSMenu {
        try #require(
            NSApp.mainMenu?.items.lazy.compactMap(\.submenu).first { $0.title == "Edit" }, "the Edit menu")
    }

    private func rightClick(on view: NSView) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: view.convert(NSPoint(x: 4, y: 4), to: nil),
                modifierFlags: [],
                timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
    }
}

/// The fix's draft, as a row of the Errors tab holds it, and whether the row shows the field.
@MainActor
@Observable
private final class FixDraft {
    var text = "- c1 | mauve"
    var shown = true
}

/// A row's fix: the draft's text, which SwiftUI updates the row for as it changes, and its field.
private struct FixHost: View {
    let draft: FixDraft

    var body: some View {
        VStack {
            Text(draft.text)
            if draft.shown {
                FixTextField(text: Binding(get: { draft.text }, set: { draft.text = $0 }))
            }
        }
    }
}

/// A fix's field in a window of its own, editing `FixDraft`'s text, with its editor focused.
@MainActor
private func withFixField(
    _ body: (AdmittingTextField, AdmittingTextView, FixDraft, NSWindow) async throws -> Void
) async throws {
    let draft = FixDraft()
    let view = FixHost(draft: draft)
    let window = await hostOffscreen(view, size: CGSize(width: 300, height: 120)) { window in
        subviewTree(of: window.contentView).contains { $0 is AdmittingTextField }
    }
    defer { window.close() }
    let field = try #require(
        subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first)
    #expect(field.stringValue == "- c1 | mauve", "precondition: the field shows the draft")
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? AdmittingTextView)
    try await body(field, editor, draft, window)
}

/// Waits for SwiftUI to update the fix's field, which hands its editor a new `onChange`.
@MainActor
private func nextUpdate(of editor: AdmittingTextView) async {
    editor.onChange = nil
    await eventually { editor.onChange != nil }
}

/// Every editor of the book's text, each named: the page, the title's own editor while it edits,
/// the notes, a comment card, and File a Copy's tag and note.
@MainActor
func withEditors(_ body: ([(String, NSTextView)]) async throws -> Void) async throws {
    try await withPage([scene("One", letterScene, .withTooEarly)]) { page in
        #expect(page.window.makeFirstResponder(page.title))
        let title = try #require(
            page.title.currentEditor() as? AdmittingTextView, "the title's own field editor, editing")
        let notes = try await page.showNotes()
        page.preferences.showRightPanelTab(.comments)
        await eventually { page.card(noted) != nil }
        let card = try #require(page.card(noted), "the comment's card")
        let flow = FilingFlow(book: page.book)
        flow.begin(today: try #require(CalendarDay(year: 2026, month: 11, day: 7)))
        let tags = try #require(
            TagTextField.field("", TagTextField.Coordinator(draft: flow.draftBinding)).editor)
        let note = try #require(
            NoteTextView.scrollView("", NoteTextView.Coordinator(draft: flow.draftBinding)).documentView
                as? AdmittingTextView)
        try await body([
            ("page", page.page), ("title", title), ("notes", notes), ("comment card", card),
            ("File a Copy's tags", tags), ("File a Copy's note", note),
        ])
    }
}

/// Every item of `menu` and its submenus.
func allItems(of menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
}

/// The items of `menu` and its submenus that show when it opens.
func shownItems(of menu: NSMenu) -> [NSMenuItem] {
    menu.items.filter { !$0.isHidden }.flatMap { [$0] + ($0.submenu.map(shownItems) ?? []) }
}
