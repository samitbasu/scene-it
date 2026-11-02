import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Hosts `view` in an offscreen window of our own and returns the window, ordered in.
private func hostOffscreen(_ view: some View, size: CGSize = CGSize(width: 600, height: 200)) async throws
    -> NSWindow
{
    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(300))
    return window
}

private func textFields(in view: NSView?) -> [NSTextField] {
    guard let view else { return [] }
    let own = (view as? NSTextField).map { [$0] } ?? []
    return own + view.subviews.flatMap(textFields)
}

@Suite(.timeLimit(.minutes(1)))
struct SceneTitleFieldTests {
    @Test func typingInTheTitleFieldReachesBookJsonOnOneLine() async throws {
        try await withTemporaryFolder { folder in
            let store = BookController(role: .testHost).store
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            await eventually { book.status == .saved }

            let window = try await hostOffscreen(SceneTitleField(book: book, scene: scene))
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

            let window = try await hostOffscreen(SceneTitleField(book: book, scene: scene))
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

    @Test func toggleRightPanelInTheViewMenuIsSavedInTheBook() async throws {
        try await withTemporaryFolder { folder in
            let store = BookController.shared.store
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            #expect(book.book.settings.rightPanelOpen == .open)
            let item = try #require(menuItem(titled: WindowWording.toggleRightPanel, in: NSApp.mainMenu))
            try perform(item)
            #expect(book.book.settings.rightPanelOpen == .closed)
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).settings.rightPanelOpen == .closed)
            #expect(await store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}
