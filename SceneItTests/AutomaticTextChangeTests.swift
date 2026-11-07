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
@Suite(.serialized, .timeLimit(.minutes(2)))
struct AutomaticTextChangeTests {
    @Test func noEditorChangesWordsAsTheyAreTyped() async throws {
        let plain = NSTextView(usingTextLayoutManager: true)
        #expect(
            plain.inlinePredictionType != .no && plain.smartInsertDeleteEnabled,
            "precondition: a text view as AppKit makes it fails the check")
        try await withEditors { editors in
            for (name, editor) in editors {
                #expect(automaticChanges(of: editor).isEmpty, "\(name)")
            }
            for (name, editor) in editors.prefix(3) {
                #expect(editor.isContinuousSpellCheckingEnabled, "\(name) still underlines spelling")
            }
        }
    }

    @Test func noEditorTakesAnAutomaticChangeBackOn() async throws {
        let plain = NSTextView(usingTextLayoutManager: true)
        for action in AutomaticTextChanges.actions {
            #expect(plain.responds(to: action), "precondition: AppKit's text view answers \(action)")
        }
        try await withEditors { editors in
            for (name, editor) in editors {
                editor.isAutomaticSpellingCorrectionEnabled = true
                editor.isAutomaticTextReplacementEnabled = true
                editor.isAutomaticTextCompletionEnabled = true
                editor.smartInsertDeleteEnabled = true
                editor.isAutomaticQuoteSubstitutionEnabled = true
                editor.isAutomaticDashSubstitutionEnabled = true
                editor.isAutomaticLinkDetectionEnabled = true
                editor.isAutomaticDataDetectionEnabled = true
                editor.inlinePredictionType = .yes
                #expect(automaticChanges(of: editor).isEmpty, "\(name)")

                #expect(
                    editor.responds(to: #selector(NSTextView.toggleContinuousSpellChecking(_:))),
                    "precondition: \(name) answers the menus' other actions")
                for action in AutomaticTextChanges.actions {
                    #expect(!editor.responds(to: action), "the responder chain passes \(name) by: \(action)")
                }
            }
        }
    }

    @Test func theEditMenuOffersNoAutomaticChange() throws {
        let edit = try #require(
            NSApp.mainMenu?.items.lazy.compactMap(\.submenu).first { $0.title == "Edit" }, "the Edit menu")
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

    @Test func anEditorsContextMenuOffersNoAutomaticChange() async throws {
        try await withEditors { editors in
            for (name, editor) in editors {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: .rightMouseDown, location: editor.convert(NSPoint(x: 4, y: 4), to: nil),
                        modifierFlags: [], timestamp: 0, windowNumber: editor.window?.windowNumber ?? 0,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                let menu = try #require(editor.menu(for: event), "\(name)'s context menu")
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

    static let keptSpelling = [
        #selector(NSTextView.showGuessPanel(_:)),
        #selector(NSTextView.checkSpelling(_:)),
        #selector(NSTextView.toggleContinuousSpellChecking(_:)),
        #selector(NSTextView.toggleGrammarChecking(_:)),
    ]
}

/// The page, the title's own editor while it edits, the notes and a comment card, each named.
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
        try await body([("page", page.page), ("title", title), ("notes", notes), ("comment card", card)])
    }
}

/// Which of the system's automatic changes to typed text `view` would make.
@MainActor
func automaticChanges(of view: NSTextView) -> [String] {
    [
        ("spelling correction", view.isAutomaticSpellingCorrectionEnabled),
        ("text replacement", view.isAutomaticTextReplacementEnabled),
        ("text completion", view.isAutomaticTextCompletionEnabled),
        ("smart insert and delete", view.smartInsertDeleteEnabled),
        ("quote substitution", view.isAutomaticQuoteSubstitutionEnabled),
        ("dash substitution", view.isAutomaticDashSubstitutionEnabled),
        ("link detection", view.isAutomaticLinkDetectionEnabled),
        ("data detection", view.isAutomaticDataDetectionEnabled),
        ("inline prediction", view.inlinePredictionType != .no),
    ].filter(\.1).map(\.0)
}

/// Every item of `menu` and its submenus.
func allItems(of menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
}

/// The items of `menu` and its submenus that show when it opens.
func shownItems(of menu: NSMenu) -> [NSMenuItem] {
    menu.items.filter { !$0.isHidden }.flatMap { [$0] + ($0.submenu.map(shownItems) ?? []) }
}
