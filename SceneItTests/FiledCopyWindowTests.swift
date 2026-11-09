import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// A filed copy open read-only (#33, PLAN §7.5) through the real window: Return on a selected
/// card opens it, the main window rebuilds over it with the banner, the page refuses typing,
/// nothing is written to the copy, and Close returns to the book at the scene that was open.
extension OneAtATime {
    @Suite(.serialized, .timeLimit(.minutes(2)))
    @MainActor
    struct FiledCopyWindowTests {
        static let record = FilingRecord(
            filed: CalendarDay(year: 2026, month: 10, day: 13)!, tags: ["draft 3"],
            note: "After the restructure.")

        /// Return on the selected card goes through the window's own actions to the store.
        @Test func returnOnASelectedCardOpensTheCopy() async throws {
            try await withCabinet(records: [Self.record]) { harness, _, _ in
                let copy = try #require(FiledCopyNumber(1))
                harness.cabinet.keyFocus.takeFocus()
                harness.cabinet.selected = copy
                await eventually { harness.window.firstResponder === harness.cabinet.keyFocus.view }
                try press(.return, in: harness.window)
                await eventually { harness.store.shown !== harness.book }
                let shown = try #require(harness.store.shown)
                #expect(shown.document.kind == .filedCopy)
                #expect(harness.store.current === harness.book, "the book stays open underneath")
                harness.store.closeFiledCopy()
                #expect(harness.store.shown === harness.book)
            }
        }

        /// The main window, as the app shows it: the copy's page refuses typing, and once the copy
        /// is closed the window shows the book again at its scene. The copy's file is untouched.
        @Test func theMainWindowShowsTheCopyReadOnlyAndCloseReturnsToTheBook() async throws {
            try await withTemporaryFolder { folder in
                let books = BookController(role: .testHost)
                let store = books.store
                let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
                #expect(await store.create(at: url) == .created)
                let book = try #require(store.current)
                let ferry = try #require(book.addScene(after: nil))
                book.replaceBody(of: ferry, with: [[Run("The ferry left at dawn.")]])
                let letter = try #require(book.addScene(after: ferry))
                book.replaceBody(of: letter, with: [[Run("He read it twice.")]])
                guard case .filed(let outcome) = await store.fileACopy(of: book, as: Self.record),
                    outcome.isComplete
                else {
                    Issue.record("precondition: a copy is filed, locked and indexed")
                    return
                }
                book.replaceBody(of: letter, with: [[Run("Rewritten since.")]])
                let filedFile = PackageLayout(root: url).filedCopy(.first)
                let filed = try Fingerprint(filedFile)
                try #require(filed.locked, "precondition: the copy is locked")

                let size = WindowMetrics.defaultSize
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: MainWindow(books: books))
                window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
                window.orderFront(nil)
                defer { window.close() }
                @MainActor func page() -> ManuscriptTextView? {
                    subviewTree(of: window.contentView).compactMap { $0 as? ManuscriptTextView }.first
                }
                await eventually { page()?.string == "Rewritten since." }
                try #require(page()?.string == "Rewritten since.", "precondition: the book's page")

                #expect(await store.openFiledCopy(.first, of: book) == .opened)
                await eventually { page()?.string == "He read it twice." }
                let copyPage = try #require(page(), "the copy's page, at the scene the book had open")
                #expect(copyPage.string == "He read it twice.")
                #expect(copyPage.paper != .white, "the page is gray")
                let copy = try #require(store.shown)
                #expect(copy.document.kind == .filedCopy)

                window.makeFirstResponder(copyPage)
                copyPage.setSelectedRange(NSRange(location: 0, length: 0))
                copyPage.insertText("X", replacementRange: copyPage.selectedRange())
                copyPage.paste(nil)
                copyPage.deleteForward(nil)
                #expect(copyPage.string == "He read it twice.", "typing is refused")
                #expect(copy.book.scene(letter)?.body == [[Run("He read it twice.")]])
                store.saveNow()

                store.closeFiledCopy()
                await eventually { page()?.string == "Rewritten since." }
                #expect(page()?.string == "Rewritten since.", "the book again, at its scene")
                #expect(page()?.paper == .white)
                #expect(book.openScene == letter)

                #expect(await store.closeBook() == .left)
                #expect(try Fingerprint(filedFile) == filed, "the filed copy's bytes, time and lock")
                #expect(try bookOnDisk(url).scene(letter)?.body == [[Run("Rewritten since.")]])
            }
        }

        /// A book of two scenes, the second open, filed once and then changed, with its copy open
        /// over it through a test-host controller.
        private func withCopyShowing(
            _ body: (BookController, AppOpenBook, AppOpenBook, (ferry: SceneID, letter: SceneID)) async throws
                -> Void
        ) async throws {
            try await withTemporaryFolder { folder in
                let books = BookController(role: .testHost)
                let store = books.store
                let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
                #expect(await store.create(at: url) == .created)
                let book = try #require(store.current)
                let ferry = try #require(book.addScene(after: nil))
                let letter = try #require(book.addScene(after: ferry))
                guard case .filed = await store.fileACopy(of: book, as: Self.record) else {
                    Issue.record("precondition: a copy is filed")
                    return
                }
                try #require(book.openScene == letter, "precondition: the second scene is open")
                #expect(await store.openFiledCopy(.first, of: book) == .opened)
                let copy = try #require(store.shown)
                try #require(copy !== book, "precondition: the copy shows")
                try await body(books, book, copy, (ferry, letter))
                #expect(await store.closeBook() == .left)
            }
        }

        /// View → Previous Scene and Next Scene act on what the window shows: the copy, never the
        /// book hidden under it.
        @Test func previousAndNextSceneMoveInTheCopy() async throws {
            try await withCopyShowing { books, book, copy, scenes in
                #expect(books.scene(.previous) == scenes.ferry)
                #expect(books.scene(.next) == nil, "the copy's last scene")
                #expect(books.take(.previous))
                #expect(copy.openScene == scenes.ferry)
                #expect(book.openScene == scenes.letter, "the book's open scene is kept for Close")
            }
        }

        /// ⌘W (File → Close Book) while a copy shows closes the copy, as the banner's Close does.
        @Test func closeBookWhileACopyShowsClosesTheCopy() async throws {
            try await withCopyShowing { books, book, _, scenes in
                #expect(books.closeAction(from: .menu(keyWindow: nil)) == .closeCopy)
                #expect(books.press(.menu(keyWindow: nil)) == nil)
                #expect(books.store.shown === book, "the book shows again")
                #expect(books.store.current === book, "and stays open")
                #expect(book.openScene == scenes.letter)
                #expect(
                    books.closeAction(from: .menu(keyWindow: nil)) == .closeBook,
                    "the next ⌘W closes the book")
            }
        }

        /// The rail and the View menu offer no File Cabinet over a copy: it has none of its own.
        @Test func theFileCabinetIsntOfferedOverACopy() async throws {
            try await withCopyShowing { _, book, copy, _ in
                #expect(!WindowMode.offers(.fileCabinet, over: copy))
                #expect(WindowMode.offers(.scenes, over: copy) && WindowMode.offers(.search, over: copy))
                #expect(WindowMode.offers(.fileCabinet, over: book))
            }
        }
    }
}
