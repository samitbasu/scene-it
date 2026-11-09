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

                // Read aloud works on the copy (PLAN §7.5): the selection on its page reads.
                copyPage.setSelectedRange(NSRange(location: 0, length: 2))
                await eventually { books.readAloud.control == .read }
                #expect(books.readAloud.control == .read, "▶ is enabled on the copy")
                books.readAloud.press()
                #expect(books.readAloud.control == .stop)
                books.readAloud.stop()
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

        /// ⌘W held down, or pressed twice, closes the copy and stops there: a press within
        /// `closeCopyGrace` does nothing. File → Close Book reads Close Copy while a copy shows.
        @Test func aHeldOrDoubledCloseClosesOnlyTheCopy() async throws {
            try await withCopyShowing { books, book, _, _ in
                var now = ContinuousClock.now
                books.now = { now }
                #expect(books.closeItemTitle == OneBookWording.closeCopyMenuItem)
                #expect(books.press(.menu(keyWindow: nil)) == nil)
                try #require(books.store.shown === book, "precondition: the copy closed")
                #expect(books.closeItemTitle == OneBookWording.closeBookMenuItem)

                now += .milliseconds(100)
                #expect(books.closeAction(from: .menu(keyWindow: nil)) == .nothing, "a repeat")
                #expect(books.press(.menu(keyWindow: nil)) == nil)
                #expect(books.store.current === book && !books.store.isChoosing, "the book stays open")

                now += BookController.closeCopyGrace.duration
                #expect(books.closeAction(from: .menu(keyWindow: nil)) == .closeBook, "a later ⌘W closes it")
            }
        }

        /// A ⌘W held past the grace still stops at the copy: its repeats are always ignored after a
        /// copy closed, and each ⌘W swallowed starts the grace again. A fresh ⌘W after a quiet
        /// grace closes the book.
        @Test func aCloseHeldPastTheGraceStillStopsAtTheCopy() async throws {
            try await withCopyShowing { books, book, _, _ in
                var now = ContinuousClock.now
                books.now = { now }
                let grace = BookController.closeCopyGrace.duration
                #expect(books.press(.menu(keyWindow: nil)) == nil)
                try #require(books.store.shown === book, "precondition: the copy closed")

                for _ in 0..<5 {
                    now += grace * 0.8
                    #expect(books.press(.menu(keyWindow: nil, press: .repeated)) == nil)
                }
                #expect(!books.store.isChoosing, "held for four graces: the book stays open")
                now += grace * 0.8
                #expect(
                    books.closeAction(from: .menu(keyWindow: nil)) == .nothing,
                    "a fresh press inside the grace a repeat re-armed")
                now += grace * 3
                #expect(
                    books.closeAction(from: .menu(keyWindow: nil, press: .repeated)) == .nothing,
                    "a repeat is ignored however long after")
                #expect(books.closeAction(from: .menu(keyWindow: nil)) == .closeBook)
            }
        }

        /// The menu's ⌘W reads a repeat from the key event; anything else is a fresh press.
        @Test func aCloseKeyEventSaysWhetherItRepeats() throws {
            @MainActor func key(_ repeating: Bool) throws -> NSEvent {
                try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                        windowNumber: 0,
                        context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: repeating,
                        keyCode: 13))
            }
            #expect(MenuPress(try key(true)) == .repeated)
            #expect(MenuPress(try key(false)) == .first)
            #expect(MenuPress(nil) == .first)
            let click = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            #expect(MenuPress(click) == .first, "a menu chosen with the mouse")
        }

        /// Export to Word… while a copy shows exports the copy's scene, named for the copy, never
        /// the book hidden under it (PLAN §7.5).
        @Test func exportToWordWhileACopyShowsExportsTheCopy() async throws {
            try await withTemporaryFolder { folder in
                let books = BookController(role: .testHost)
                let store = books.store
                let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
                #expect(await store.create(at: url) == .created)
                let book = try #require(store.current)
                let scene = try #require(book.addScene(after: nil))
                book.setTitle(of: scene, to: "The ferry")
                book.replaceBody(of: scene, with: [[Run("As it was filed.")]])
                guard case .filed = await store.fileACopy(of: book, as: Self.record) else {
                    Issue.record("precondition: a copy is filed")
                    return
                }
                book.replaceBody(of: scene, with: [[Run("Rewritten since.")]])
                #expect(await store.openFiledCopy(.first, of: book) == .opened)
                let copy = try #require(store.shown)
                try #require(copy !== book, "precondition: the copy shows")
                let exported = try #require(books.wordExportScene)
                #expect(exported.book === copy)
                #expect(
                    WordExportWording.defaultFileName(scene: exported.scene, of: copy.document)
                        == "The ferry, \(ArchiveWording.day(Self.record.filed)).docx")
                let destination = folder.appending(path: "Filed.docx")
                books.wordDestination = .fixed(destination)

                #expect(await books.exportToWord() == .exported)

                let read = try NSAttributedString(
                    url: destination, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                    documentAttributes: nil)
                #expect(read.string.contains("As it was filed."), "the copy's text")
                #expect(!read.string.contains("Rewritten since."))
                store.closeFiledCopy()
                #expect(await store.closeBook() == .left)
            }
        }

        /// With Include comments ticked, a filed copy's export carries the copy's comments, not the
        /// book's as they are now (ADR 0048).
        @Test func exportToWordWhileACopyShowsExportsTheCopysComments() async throws {
            try await withTemporaryFolder { folder in
                let books = BookController(role: .testHost)
                let store = books.store
                let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
                #expect(await store.create(at: url) == .created)
                let book = try #require(store.current)
                let scene = try #require(book.addScene(after: nil))
                try OneAtATime.BookStoreIntegrationTests.comment(scene, of: book)
                guard case .filed = await store.fileACopy(of: book, as: Self.record) else {
                    Issue.record("precondition: a copy is filed")
                    return
                }
                let comment = try #require(book.book.scene(scene)?.comments.first)
                try #require(book.setText("Changed since.", ofComment: comment.id, in: scene))
                #expect(await store.openFiledCopy(.first, of: book) == .opened)
                try #require(store.shown !== book, "precondition: the copy shows")
                let destination = folder.appending(path: "Filed.docx")
                books.wordDestination = .fixed(destination, choosing: .include)

                #expect(await books.exportToWord() == .exported)

                let comments = try #require(
                    try OneAtATime.BookStoreIntegrationTests.exportedComments(destination))
                #expect(comments.contains(">Check the schedule.<"), "the copy's comment")
                #expect(!comments.contains("Changed since."))
                store.closeFiledCopy()
                #expect(await store.closeBook() == .left)
            }
        }

        /// The banner's Restore and New Book stay enabled; refused, they tell the writer why and
        /// write nothing: Restore into a book open elsewhere, a new book from a copy a newer Scene
        /// It wrote.
        @Test func aRefusedBannerActionSaysWhyAndWritesNothing() async throws {
            try await withTemporaryFolder { folder in
                let prompts = TellingPrompts()
                let books = BookController(role: .testHost, prompts: prompts)
                let store = books.store
                let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
                #expect(await store.create(at: url) == .created)
                let first = try #require(store.current)
                _ = try #require(first.addScene(after: nil))
                guard case .filed = await store.fileACopy(of: first, as: Self.record) else {
                    Issue.record("precondition: a copy is filed")
                    return
                }
                #expect(await store.closeBook() == .left)
                let file = PackageLayout(root: url).filedCopy(.first)
                try FileManager.default.setAttributes(
                    [.immutable: false], ofItemAtPath: file.path(percentEncoded: false))
                let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
                try #require(text.contains("format: 2\n"), "precondition: the copy declares its format")
                try Data(text.replacingOccurrences(of: "format: 2\n", with: "format: 3\n").utf8).write(
                    to: file)
                let holder = try #require(try BookPackage.open(at: url).editable)
                #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
                let book = try #require(store.current)
                #expect(await store.openFiledCopy(.first, of: book) == .opened)
                let copy = try #require(store.shown)
                let made = folder.appending(path: "Then.sceneit", directoryHint: .isDirectory)
                let actions = FiledCopyActions(copy: copy, store: store, newBook: .fixed(made))
                let bookBytes = try Data(contentsOf: url.appending(path: "book.md"))
                let told = prompts.titles.count

                await actions.restore()
                await actions.makeNewBook()

                #expect(Array(prompts.titles.dropFirst(told)).count == 2, "each said why")
                #expect(prompts.titles.last == store.refusalToMakeBook(from: copy)?.title)
                #expect(!FileManager.default.fileExists(atPath: made.path(percentEncoded: false)))
                #expect(try Data(contentsOf: url.appending(path: "book.md")) == bookBytes)
                #expect(store.shown === copy, "still showing the copy")
                store.closeFiledCopy()
                #expect(await store.closeBook() == .left)
                withExtendedLifetime(holder) {}
            }
        }
    }
}

/// Records what the store tells and asks, answering each question with its first choice.
@MainActor
private final class TellingPrompts: StorePrompts {
    private(set) var titles: [String] = []

    func ask<Choice>(_ alert: WriterAlert<Choice>) async -> Choice {
        titles.append(alert.title)
        return alert.choices[0]
    }

    func tell(_ notice: Notice) async {
        titles.append(notice.title)
    }
}
