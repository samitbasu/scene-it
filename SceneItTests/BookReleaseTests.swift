import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// Runs the main run loop for a moment inside a pool of its own, so whatever the turns it runs
/// autorelease is released when they end. The test host's outermost pool is never drained.
/// It runs from the run loop, never inside the test's job: a run loop nested in a job makes
/// every block it runs, other tests' included, run with a task current (`UnwoundJobTrapTests`).
@MainActor
private func drainARunLoopTurn() async {
    await onTheRunLoop {
        autoreleasepool {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}

extension BookStoreIntegrationTests {
    /// #88: closing a book in the app's own window, through File → Close Book, releases the
    /// `OpenBook` and the page's editor, while the window stays up for the start screen. (The page's `NSTextView` itself outlives
    /// them for a while, held by AppKit: a block `-[NSView _commonAwake]` registers with the
    /// notification center, and AppKit's `previousKeyViews` table. It no longer reaches the
    /// book, since its editor is weak and gone, so it isn't asserted on.) Any AppKit call from a
    /// test's task that reads the view's weak delegate autoreleases the editor into the never-drained
    /// pool, and so keeps it alive here.
    @Test func aClosedBookIsReleasedWithItsEditor() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            try #require(await books.store.create(at: url) == .created)
            weak let book = books.store.current
            let scene = try #require(book?.addScene(after: nil))
            book?.replaceBody(of: scene, with: [[Run("Release me.")]])
            // In a pool of its own: AppKit's `subviews` arrays are autoreleased, and a lookup in
            // the never-drained outer pool would keep the views (and so the editor) alive.
            @MainActor func page() -> ManuscriptTextView? {
                autoreleasepool {
                    NSApp.windows.lazy.flatMap { subviewTree(of: $0.contentView) }
                        .compactMap { $0 as? ManuscriptTextView }.first { $0.string == "Release me." }
                }
            }
            await eventually { page() != nil }
            weak let editor = autoreleasepool { page()?.editor }
            try #require(book != nil && editor != nil, "precondition: both alive while the book is open")
            try #require(editor?.book === book, "precondition: the editor is the open book's")

            let window = try #require(books.mainWindow, "precondition: the app's main window")

            await books.press(.menu(keyWindow: nil))?.value
            await eventually { books.store.isChoosing && page() == nil }
            #expect(window.isVisible, "the window stays up for the start screen")

            let deadline = ContinuousClock.now + .seconds(30)
            while book != nil || editor != nil, ContinuousClock.now < deadline {
                await drainARunLoopTurn()
            }
            #expect(book == nil, "the closed OpenBook was released")
            #expect(editor == nil, "the page's editor was released")
            expectNoQuestions()
        }
    }
}
