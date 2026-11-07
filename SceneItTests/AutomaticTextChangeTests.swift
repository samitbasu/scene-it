import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// #127: the writer's words are changed only by the writer. No editor of the book's text makes
/// an automatic change, no menu offers one, and nothing turns one back on. The toggle actions
/// themselves are never sent: AppKit may record them in the app's defaults.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(4)))
struct AutomaticTextChangeTests {
    @Test func noEditorIsSetToChangeWordsAsTheyAreTyped() async throws {
        let plain = NSTextView(usingTextLayoutManager: true)
        #expect(
            automaticChanges(of: plain).contains("smart insert and delete"),
            "precondition: a text view as AppKit makes it fails the check")
        try await withEditors { editors in
            for (name, editor) in editors {
                #expect(automaticChanges(of: editor) == [], "\(name)")
            }
            for (name, editor) in editors.prefix(3) {
                #expect(editor.isContinuousSpellCheckingEnabled, "\(name) still underlines spelling")
            }
        }
    }

    @Test func noEditorTakesAnAutomaticChangeBackOn() async throws {
        let plain = NSTextView(usingTextLayoutManager: true)
        turnOnEveryAutomaticChange(plain)
        #expect(
            Set(automaticChanges(of: plain)).isSuperset(of: [
                "spelling correction", "text replacement", "smart quotes",
            ]),
            "precondition: the switches turn them on in AppKit's text view")
        for action in AutomaticTextChanges.actions {
            #expect(plain.responds(to: action), "precondition: AppKit's text view answers \(action)")
        }
        try await withEditors { editors in
            for (name, editor) in editors {
                turnOnEveryAutomaticChange(editor)
                #expect(automaticChanges(of: editor) == [], "\(name)")
                #expect(
                    editor.responds(to: #selector(NSTextView.toggleContinuousSpellChecking(_:))),
                    "precondition: \(name) answers the menus' other actions")
                for action in AutomaticTextChanges.actions {
                    #expect(!editor.responds(to: action), "the responder chain passes \(name) by: \(action)")
                }
            }
        }
    }

    /// What's typed on the page and then checked, as AppKit checks it, is marked, never changed,
    /// even with every switch flipped back on. AppKit's own text view, checked the same way,
    /// curls the quotes and links the address. Its autocorrection runs only on a real key's
    /// space, so a checking pass is the path a test can drive; and since the character policy
    /// would straighten curled quotes again, the link is what shows a change on the page.
    @Test func textTypedOnThePageIsMarkedNotChanged() async throws {
        let typed = " I saw teh omw, say \"hi\" at www.example.com "
        let plain = NSTextView(usingTextLayoutManager: true)
        plain.isAutomaticQuoteSubstitutionEnabled = true
        plain.isAutomaticLinkDetectionEnabled = true
        plain.insertText(typed, replacementRange: NSRange(location: 0, length: 0))
        plain.checkTextInDocument(nil)
        await eventually { plain.string != typed }
        #expect(
            plain.string.contains("\u{201C}hi\u{201D}"), "precondition: AppKit curls quotes where it's let")
        #expect(links(in: plain) != [], "precondition: AppKit links an address where it's let")

        try await withPage([scene("One", [[Run("Start.")]])]) { page in
            turnOnEveryAutomaticChange(page.page)
            page.focusPage(at: 6)
            page.page.insertText(typed, replacementRange: page.page.selectedRange())
            let teh = (page.page.string as NSString).range(of: "teh")
            // In a full run the spelling service, shared with every other test's editors, has
            // left a check unanswered for more than `eventually`'s 30 s, so it's waited for
            // longer and asked again now and then.
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(150)
            var asked = clock.now - .seconds(10)
            while clock.now < deadline,
                !spellingMarks(in: page.page).contains(where: { NSIntersectionRange($0, teh).length > 0 })
            {
                if clock.now - asked >= .seconds(10) {
                    page.page.checkTextInDocument(nil)
                    asked = clock.now
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(
                spellingMarks(in: page.page).contains { NSIntersectionRange($0, teh).length > 0 },
                "precondition: the check ran and marked teh")
            #expect(page.page.string == "Start." + typed)
            #expect(links(in: page.page) == [])
            #expect(page.pageMirrorsModel)
        }
    }

    private func links(in view: NSTextView) -> [NSRange] {
        var found: [NSRange] = []
        let storage = view.textStorage ?? NSTextStorage()
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            if value != nil { found.append(range) }
        }
        return found
    }

    /// A word pasted against a word gets no space added, as smart copy and paste would add.
    @Test func aWordPastedAgainstAWordGetsNoSpace() async throws {
        try await PageHarness.withPasteboard { pasteboard in
            @MainActor func smartPaste(_ word: String) {
                pasteboard.clearContents()
                pasteboard.declareTypes([.string, Self.smartPaste], owner: nil)
                pasteboard.setString(word, forType: .string)
                pasteboard.setData(Data(), forType: Self.smartPaste)
            }
            let plain = NSTextView(usingTextLayoutManager: true)
            plain.smartInsertDeleteEnabled = true
            plain.string = "Hello."
            plain.setSelectedRange(NSRange(location: 5, length: 0))
            smartPaste("world")
            #expect(plain.readSelection(from: pasteboard))
            #expect(plain.string == "Hello world.", "precondition: AppKit adds the space where it's let")

            try await withPage([scene("One", [[Run("Hello.")]])]) { page in
                page.focusPage(at: 5)
                smartPaste("world")
                #expect(page.page.readSelection(from: pasteboard))
                #expect(page.page.string == "Helloworld.")
                #expect(page.body() == [[Run("Helloworld.")]])
            }
        }
    }

    @Test func theEditMenuOffersNoAutomaticChange() throws {
        let edit = try editMenu()
        #expect(
            allItems(of: edit).contains(where: AutomaticTextChanges.isAutomatic),
            "precondition: the system put automatic changes in the Edit menu")
        #expect(shownItems(of: edit).filter(AutomaticTextChanges.isAutomatic).map(\.title) == [])
        #expect(!shownItems(of: edit).contains { $0.title == "Substitutions" })
        let shown = Set(shownItems(of: edit).compactMap(\.action))
        for kept in Self.keptSpelling {
            #expect(shown.contains(kept), "\(kept)")
        }
    }

    /// SwiftUI may show an item again as it updates the menu; it's hidden again before the menu
    /// bar opens.
    @Test func anItemShownAgainIsHiddenAgainBeforeTheMenuOpens() throws {
        let item = try #require(
            allItems(of: try editMenu()).first {
                $0.action == #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))
            }, "Correct Spelling Automatically")
        #expect(item.isHidden, "precondition: hidden")
        item.isHidden = false
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu)
        #expect(item.isHidden)
    }

    @Test func anEditorsContextMenuOffersNoAutomaticChange() async throws {
        try await withEditors { editors in
            for (name, editor) in editors {
                let menu = try #require(editor.menu(for: rightClick(on: editor)), "\(name)'s context menu")
                #expect(
                    allItems(of: menu).contains(where: AutomaticTextChanges.isAutomatic),
                    "precondition: AppKit's menu for \(name) offers automatic changes")
                #expect(
                    shownItems(of: menu).filter(AutomaticTextChanges.isAutomatic).map(\.title) == [],
                    "\(name)")
                let shown = Set(shownItems(of: menu).compactMap(\.action))
                #expect(shown.contains(#selector(NSTextView.toggleContinuousSpellChecking(_:))), "\(name)")
            }
        }
    }

    /// Hiding items in one context menu leaves AppKit's own menu, and every other, alone.
    @Test func aContextMenuSharesNoSubmenuWithAppKits() async throws {
        try await withPage([scene("One", [[Run("Hello.")]])]) { page in
            let first = try #require(page.page.menu(for: try rightClick(on: page.page)))
            let second = try #require(page.page.menu(for: try rightClick(on: page.page)))
            let appKits = allItems(of: NSTextView.defaultMenu ?? NSMenu()).compactMap(\.submenu)
            let firsts = allItems(of: first).compactMap(\.submenu)
            try #require(!firsts.isEmpty, "precondition: the menu has submenus")
            for submenu in firsts {
                #expect(!appKits.contains { $0 === submenu }, "\(submenu.title)")
                #expect(
                    !allItems(of: second).compactMap(\.submenu).contains { $0 === submenu },
                    "\(submenu.title)")
            }
            #expect(
                allItems(of: NSTextView.defaultMenu ?? NSMenu()).filter(AutomaticTextChanges.isAutomatic)
                    .allSatisfy { !$0.isHidden }, "AppKit's own menu is untouched")
        }
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
            #expect(automaticChanges(of: editor) == [])
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

    /// What's typed in a fix's field reaches the row's draft, which Apply applies.
    @Test func aFixsFieldPassesWhatsTypedToTheDraft() async throws {
        final class Draft {
            var text = "- c1 | mauve"
        }
        let draft = Draft()
        let window = await hostOffscreen(
            FixTextField(text: Binding(get: { draft.text }, set: { draft.text = $0 })),
            size: CGSize(width: 300, height: 120)
        ) { window in subviewTree(of: window.contentView).contains { $0 is AdmittingTextField } }
        defer { window.close() }
        let field = try #require(
            subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first)
        #expect(field.stringValue == "- c1 | mauve", "precondition: the field shows the draft")
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? AdmittingTextView)
        editor.setSelectedRange(NSRange(location: 7, length: 5))
        editor.insertText("purple", replacementRange: editor.selectedRange())
        #expect(draft.text == "- c1 | purple")
    }

    static let keptSpelling = [
        #selector(NSTextView.showGuessPanel(_:)),
        #selector(NSTextView.checkSpelling(_:)),
        #selector(NSTextView.toggleContinuousSpellChecking(_:)),
        #selector(NSTextView.toggleGrammarChecking(_:)),
    ]

    static let smartPaste = NSPasteboard.PasteboardType("NeXT smart paste pasteboard type")

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

    /// `root` and every accessibility element under it; SwiftUI's buttons may be elements only.
    private static func accessibilityTree(of root: Any?) -> [NSAccessibilityProtocol] {
        guard let element = root as? NSAccessibilityProtocol else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap(accessibilityTree)
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

    private func turnOnEveryAutomaticChange(_ view: NSTextView) {
        view.enabledTextCheckingTypes = .max
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        view.isAutomaticTextCompletionEnabled = true
        view.smartInsertDeleteEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticDashSubstitutionEnabled = true
        view.isAutomaticLinkDetectionEnabled = true
        view.isAutomaticDataDetectionEnabled = true
        view.inlinePredictionType = .yes
    }
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

/// Which of the system's automatic changes to typed text `view` is set to make, as AppKit holds
/// them: its text checking beyond spelling and grammar, and the switches that aren't checking.
@MainActor
func automaticChanges(of view: NSTextView) -> [String] {
    let types = view.enabledTextCheckingTypes
    let checking: [(String, NSTextCheckingResult.CheckingType)] = [
        ("spelling correction", .correction), ("text replacement", .replacement), ("smart quotes", .quote),
        ("smart dashes", .dash), ("link detection", .link), ("date detection", .date),
    ]
    let named = checking.reduce(0) { $0 | $1.1.rawValue }
    let other = types & ~(named | KeyboardTextView.checkedTypes) == 0 ? [] : ["other text checking"]
    let switches = [
        ("text completion", view.isAutomaticTextCompletionEnabled),
        ("smart insert and delete", view.smartInsertDeleteEnabled),
        ("inline prediction", view.inlinePredictionType != .no),
    ]
    return checking.filter { types & $0.1.rawValue != 0 }.map(\.0) + other + switches.filter(\.1).map(\.0)
}

/// Every item of `menu` and its submenus.
func allItems(of menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
}

/// The items of `menu` and its submenus that show when it opens.
func shownItems(of menu: NSMenu) -> [NSMenuItem] {
    menu.items.filter { !$0.isHidden }.flatMap { [$0] + ($0.submenu.map(shownItems) ?? []) }
}

/// The ranges of `view`'s text marked as misspelled or ungrammatical.
@MainActor
func spellingMarks(in view: NSTextView) -> [NSRange] {
    guard let layout = view.textLayoutManager, let content = layout.textContentManager else { return [] }
    var marks: [NSRange] = []
    layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) {
        _, attributes, range in
        if attributes[.spellingState] != nil {
            marks.append(
                NSRange(
                    location: content.offset(from: content.documentRange.location, to: range.location),
                    length: content.offset(from: range.location, to: range.endLocation)))
        }
        return true
    }
    return marks
}
