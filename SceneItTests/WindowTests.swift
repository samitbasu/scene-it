import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// The scene's title field, hosted offscreen once SwiftUI has made it.
private func hostTitleField(of book: AppOpenBook, _ scene: SceneID) async -> NSWindow {
    await hostOffscreen(SceneTitleField(book: book, scene: scene), size: CGSize(width: 600, height: 200)) {
        !textFields(in: $0.contentView).isEmpty
    }
}

private func textFields(in view: NSView?) -> [NSTextField] {
    subviewTree(of: view).compactMap { $0 as? NSTextField }
}

@Suite(.timeLimit(.minutes(1)))
struct SceneTitleFieldTests {
    @Test func typingInTheTitleFieldReachesBookMdOnOneLine() async throws {
        try await withTemporaryFolder { folder in
            let store = BookController(role: .testHost).store
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            await eventually { book.status == .saved }

            let window = await hostTitleField(of: book, scene)
            defer { window.close() }
            let fields = textFields(in: window.contentView).filter(\.isEditable)
            try #require(fields.count == 1, "one editable field, the title")
            #expect(window.makeFirstResponder(fields[0]))
            let editor = try #require(fields[0].currentEditor() as? NSTextView)
            editor.insertText("The ferry\nat dawn", replacementRange: editor.selectedRange())

            #expect(book.book.scene(scene)?.title == "The ferry at dawn")
            #expect(book.status == .unsaved)
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes.first?.title == "The ferry at dawn")
            #expect(await store.closeBook() == .left)
        }
    }

    /// ADR 0028: the title has no input method, and what reaches it is spelled in ASCII.
    @Test func theTitleFieldTakesOnlyWhatThePolicyAdmits() async throws {
        try await withTemporaryFolder { folder in
            let store = BookController(role: .testHost).store
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))

            let window = await hostTitleField(of: book, scene)
            defer { window.close() }
            let fields = textFields(in: window.contentView).filter(\.isEditable)
            try #require(fields.count == 1, "one editable field, the title")
            #expect(window.makeFirstResponder(fields[0]))
            let editor = try #require(fields[0].currentEditor() as? NSTextView)
            #expect(editor.inputContext == nil)
            editor.insertText(
                "Caf\u{E9} \u{201C}Ren\u{E9}e\u{201D}", replacementRange: editor.selectedRange())
            #expect(book.book.scene(scene)?.title == "Cafe \"Renee\"")
            #expect(editor.string == "Cafe \"Renee\"")
            editor.setMarkedText(
                " \u{65E5}", selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(!editor.hasMarkedText())
            #expect(book.book.scene(scene)?.title == "Cafe \"Renee\" [?]")
            #expect(await store.closeBook() == .left)
        }
    }

    /// ADR 0024 through the app's store: a book repaired as it opened is read-only (the test
    /// host's alerts answer Keep Read-Only), and Make Editable makes the page editable.
    @Test func aDamagedBookOpensReadOnlyAndMakeEditableLetsTheWriterType() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Damaged.sceneit", directoryHint: .isDirectory)
            var draft = Book(title: "Damaged")
            var ids = IDGenerator<SystemRandomNumberGenerator>.system
            draft.scenes = [
                BookScene(id: ids.sceneID(), modified: Timestamp(.now, in: .current), title: "Kept")
            ]
            _ = try BookPackage.create(at: url, title: "Damaged")
            let damaged = Data("A line a sync tool left\n".utf8) + BookFormat.serialize(draft)
            try damaged.write(to: url.appending(path: "book.md"))
            let books = BookController(role: .testHost)
            let store = books.store
            guard case .openedReadOnly(.repairedOnOpen) = await store.open(url) else {
                Issue.record("expected the book to open read-only, repaired")
                return
            }
            #expect((books.prompts as? HeadlessPrompts)?.takeTitles() == [ReadOnlyWording.readOnlyTitle])
            let book = try #require(store.current)
            let scene = try #require(book.openScene)
            do {
                let window = await hostTitleField(of: book, scene)
                defer { window.close() }
                let fields = textFields(in: window.contentView)
                try #require(!fields.isEmpty)
                #expect(fields.allSatisfy { !$0.isEditable || !$0.isEnabled })
            }

            #expect(await store.makeEditable() == .editable)
            let window = await hostTitleField(of: book, scene)
            defer { window.close() }
            let fields = textFields(in: window.contentView).filter(\.isEditable)
            try #require(fields.count == 1, "the title is editable now")
            #expect(window.makeFirstResponder(fields[0]))
            let editor = try #require(fields[0].currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText("Repaired", replacementRange: editor.selectedRange())
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes.first?.title == "Repaired")
            let originals = try FileManager.default.contentsOfDirectory(
                atPath: url.path(percentEncoded: false)
            )
            .filter { $0.hasPrefix("book.md.original-") }
            #expect(originals.count == 1)
            #expect(try originals.map { try Data(contentsOf: url.appending(path: $0)) } == [damaged])
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func theTitleFieldIsDisabledForAReadOnlyBook() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Held.sceneit", directoryHint: .isDirectory)
            var draft = Book(title: "Held")
            var ids = IDGenerator<SystemRandomNumberGenerator>.system
            draft.scenes = [
                BookScene(id: ids.sceneID(), modified: Timestamp(.now, in: .current), title: "Kept")
            ]
            let holder = try BookPackage.create(at: url, title: "Held")
            _ = try holder.package.save(draft)
            let store = BookController(role: .testHost).store
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            let book = try #require(store.current)
            let scene = try #require(book.openScene)

            let window = await hostTitleField(of: book, scene)
            defer { window.close() }
            let fields = textFields(in: window.contentView)
            try #require(!fields.isEmpty)
            #expect(fields.allSatisfy { !$0.isEditable || !$0.isEnabled })
            #expect(await store.closeBook() == .left)
            withExtendedLifetime(holder) {}
        }
    }
}

extension BookStoreIntegrationTests {
    @Test func theViewMenuHasTheSheetsAndTheRightPanel() {
        let expected: [(String, String, NSEvent.ModifierFlags)] = [
            ("Scenes", "1", [.command]),
            ("Search", "f", [.command, .shift]),
            ("File Cabinet", "", []),
            (WindowWording.toggleRightPanel, "]", [.command]),
        ]
        for (title, key, modifiers) in expected {
            let item = menuItem(titled: title, in: NSApp.mainMenu)
            #expect(item != nil, "\(title)")
            #expect(item?.keyEquivalent == key, "\(title)")
            if !key.isEmpty {
                #expect(item?.keyEquivalentModifierMask == modifiers, "\(title)")
            }
        }
    }

    /// SwiftUI refreshes a menu's items when AppKit asks the menu to update, as it does when
    /// the writer opens it or presses a shortcut, and may replace them; so each look asks for
    /// that update and then finds the item again.
    private var toggleRightPanel: NSMenuItem? {
        if let menu = menuItem(titled: WindowWording.toggleRightPanel, in: NSApp.mainMenu)?.menu {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
        }
        return menuItem(titled: WindowWording.toggleRightPanel, in: NSApp.mainMenu)
    }

    @Test func toggleRightPanelIsAPreferenceAndNeedsABook() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.current == nil)
            await eventually { toggleRightPanel?.isEnabled == false }

            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            await eventually { toggleRightPanel?.isEnabled == true }
            let before = books.preferences.rightPanel
            try perform(try #require(toggleRightPanel))
            #expect(books.preferences.rightPanel != before)
            #expect(book.status == .saved, "the panel isn't part of the book (ADR 0022)")
            try perform(try #require(toggleRightPanel))
            #expect(books.preferences.rightPanel == before)

            #expect(await store.closeBook() == .left)
            await eventually { toggleRightPanel?.isEnabled == false }
            expectNoQuestions()
        }
    }
}
