import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

@Observable
private final class ModeBox {
    var mode = WindowMode.page
}

/// `BookWindow` with its mode in `box`, so the test can open a sheet as the rail would.
private struct Harness: View {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    @Bindable var box: ModeBox

    var body: some View {
        BookWindow(book: book, store: store, preferences: preferences, mode: $box.mode)
    }
}

private func views(in view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap(views)
}

/// Whether a writer could type into `view`, other than through a field's field editor. SwiftUI
/// may keep a replaced view in the window, hidden, which takes no keystrokes and no Tab.
private func takesTyping(_ view: NSView) -> Bool {
    guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
    switch view {
    case let field as NSTextField: return field.isEditable && field.isEnabled
    case let text as NSTextView: return text.isEditable && !text.isFieldEditor
    default: return false
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SheetFocusTests {
    @Test func aSheetTakesTheFocusFromThePageAndDisablesWhatItCovers() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            try #require(book.addScene(after: nil) != nil)

            let box = ModeBox()
            let size = WindowMetrics.defaultSize
            let controller = NSHostingController(
                rootView: Harness(book: book, store: books.store, preferences: books.preferences, box: box))
            controller.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
            window.orderFront(nil)
            defer { window.close() }

            @MainActor func editors() -> [NSView] { views(in: window.contentView).filter(takesTyping) }
            await eventually {
                editors().contains { $0 is NSTextField } && editors().contains { $0 is NSTextView }
            }
            let editors = editors()
            let title = try #require(editors.compactMap { $0 as? NSTextField }.first)
            let body = try #require(editors.compactMap { $0 as? NSTextView }.first)
            #expect(editors.count == 2, "precondition: the page's only editors are its title and body")
            let page = try #require(title.ancestorShared(with: body))
            #expect(page !== window.contentView, "precondition: the page is narrower than the window")

            #expect(window.makeFirstResponder(title))
            let editor = try #require(window.firstResponder as? NSText)
            #expect(editor.delegate === title, "precondition: the title field has the focus")

            box.mode = .scenes
            await eventually {
                !(window.firstResponder is NSText) && !views(in: page).contains(where: takesTyping)
            }
            #expect(!(window.firstResponder is NSText), "no text in the covered page keeps the focus")
            #expect(title.window === window, "precondition: the title field is still there, under the sheet")
            #expect(!title.isEnabled, "the title field is disabled under the sheet")
            #expect(!views(in: page).contains(where: takesTyping), "nothing on the covered page takes typing")

            box.mode = .page
            @MainActor func bodyTakesTyping() -> Bool {
                views(in: page).contains { $0 is NSTextView && takesTyping($0) }
            }
            await eventually { title.isEnabled && bodyTakesTyping() }
            #expect(title.isEnabled, "the title field is usable again once the sheet closes")
            #expect(bodyTakesTyping(), "the body is usable again once the sheet closes")
            #expect(await books.store.closeBook() == .left)
        }
    }

    @Test func theTestHostsPreferencesNeverReachTheWritersDefaults() {
        #expect(BookController.shared.preferences.storage is TransientPreferenceStorage)
        #expect(BookController(role: .testHost).preferences.storage is TransientPreferenceStorage)
    }
}
