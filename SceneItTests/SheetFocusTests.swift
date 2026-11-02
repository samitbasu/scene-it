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
    let preferences: AppPreferences
    @Bindable var box: ModeBox

    var body: some View {
        BookWindow(book: book, preferences: preferences, mode: $box.mode)
    }
}

private func views(in view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap(views)
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
                rootView: Harness(book: book, preferences: books.preferences, box: box))
            controller.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))

            let title = try #require(
                views(in: window.contentView).compactMap { $0 as? NSTextField }.first { $0.isEditable })
            #expect(window.makeFirstResponder(title))
            let editor = try #require(window.firstResponder as? NSText)
            #expect(editor.delegate === title, "precondition: the title field has the focus")

            box.mode = .scenes
            try await Task.sleep(for: .milliseconds(400))
            #expect(!(window.firstResponder is NSText), "no text in the covered page keeps the focus")
            let pageText = views(in: window.contentView).filter { $0 is NSTextField || $0 is NSTextView }
            #expect(!pageText.isEmpty, "precondition: the page is still there, under the sheet")
            for view in pageText {
                if let field = view as? NSTextField, field.isEditable {
                    #expect(!field.isEnabled, "the title field is disabled under the sheet")
                }
                if let text = view as? NSTextView {
                    #expect(!text.isEditable || !text.isSelectable, "the body is disabled under the sheet")
                }
            }

            box.mode = .page
            try await Task.sleep(for: .milliseconds(400))
            #expect(title.isEnabled, "the page is usable again once the sheet closes")
            #expect(await books.store.closeBook() == .left)
        }
    }

    @Test func theTestHostsPreferencesNeverReachTheWritersDefaults() {
        #expect(BookController.shared.preferences.storage is TransientPreferenceStorage)
        #expect(BookController(role: .testHost).preferences.storage is TransientPreferenceStorage)
    }
}
