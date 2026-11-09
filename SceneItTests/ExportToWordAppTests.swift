import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// Export to Word… in the app (PLAN §10.2): the File menu's item, enabled while a scene is open, and
/// the document it writes for the open scene. The test host's save panel names a file in the test's
/// own folder, so nothing here reaches the owner's files.
extension OneAtATime.BookStoreIntegrationTests {
    @Test func theFileMenuHasExportToWordAfterExportAsSceneIt() throws {
        let item = try #require(menuItem(titled: WordExportWording.menuItem, in: NSApp.mainMenu))
        let menu = try #require(item.menu)
        let sceneIt = try #require(menuItem(titled: ExportWording.menuItem, in: menu))
        #expect(menu.index(of: item) == menu.index(of: sceneIt) + 1)
        #expect(item.keyEquivalent.isEmpty, "no shortcut")
    }

    /// Export to Word… in the File menu as it's drawn now; `nil` if it isn't there.
    @MainActor
    static func exportToWordIsEnabled() -> Bool? {
        OneBookRenders.fileMenu().items.first { $0.title == WordExportWording.menuItem }?.isEnabled
    }

    @Test func exportToWordWritesTheOpenScene() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.isChoosing, "precondition: the start screen")
            #expect(books.wordExportScene == nil)
            let url = folder.appending(path: "Tide.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            book.setTitle(of: scene, to: "The ferry")
            book.replaceBody(of: scene, with: [[Run("The ferry left at "), Run("dawn", styles: [.italic])]])
            book.select(scene)
            #expect(books.wordExportScene?.scene.id == scene)
            await eventually { Self.exportToWordIsEnabled() == true }
            #expect(Self.exportToWordIsEnabled() == true)

            let destination = folder.appending(path: "The ferry.docx")
            books.wordDestination = .fixed(destination)
            defer { books.wordDestination = .nowhere }

            #expect(await books.exportToWord() == .exported)

            let read = try NSAttributedString(
                url: destination, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil)
            #expect(read.string.hasPrefix("The ferry\nThe ferry left at dawn"))
            #expect(await store.closeBook() == .left)
            await eventually { Self.exportToWordIsEnabled() == false }
            #expect(Self.exportToWordIsEnabled() == false, "no scene to export on the start screen")
            expectNoQuestions()
        }
    }

    /// The comments' text, by Word id order, in the .docx at `url`; `nil` without a comments part.
    static func exportedComments(_ url: URL) throws -> String? {
        let docx = try Data(contentsOf: url)
        #expect(try Unzip.test(docx))
        guard try Unzip.names(docx).contains("word/comments.xml") else { return nil }
        return String(decoding: try Unzip.part("word/comments.xml", of: docx), as: UTF8.self)
    }

    /// "The ferry left at dawn", commented "Check the schedule.", in `scene` of `book`.
    static func comment(_ scene: SceneID, of book: AppOpenBook) throws {
        book.replaceBody(of: scene, with: [[Run("The ferry left at dawn.")]])
        let comment = try #require(book.newComment(in: scene, colored: .red))
        let paragraph: Paragraph = [Run("The ferry left at dawn", comments: [comment.id]), Run(".")]
        try #require(
            book.apply(BodyChange(lines: 0..<1, paragraphs: [paragraph]), to: scene, adding: [comment]) != nil
        )
        try #require(book.setText("Check the schedule.", ofComment: comment.id, in: scene))
    }

    /// The save panel's accessory is the Include comments checkbox, bound to the options the
    /// export reads (ADR 0048). It starts unticked on every export, and ticking it, through the
    /// model the checkbox shows, exports the comments.
    ///
    /// The test checks `WordDestination.accessory`, which `savePanel` sets as the panel's
    /// `accessoryView`, rather than reading it off a panel: making an `NSSavePanel` in the test
    /// host (a version of this test did, #183) stalled past the time limit in the full gate run,
    /// though it took a second alone. The panel comes from a system service shared with the rest
    /// of the session, so the test leaves it out rather than depend on that service's mood.
    @Test func theSavePanelsIncludeCommentsStartsOffAndDecidesWhatsExported() async throws {
        let options = WordExportOptions()
        #expect(options.comments == .omit, "off by default")
        let accessory = WordDestination.accessory(options)
        #expect(accessory.rootView.options === options)
        #expect(accessory.frame.width > 0 && accessory.frame.height > 0, "sized to its checkbox")

        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.isChoosing, "precondition: the start screen")
            let url = folder.appending(path: "Tide.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            try Self.comment(scene, of: book)
            book.select(scene)
            defer { books.wordDestination = .nowhere }

            let unticked = folder.appending(path: "Unticked.docx")
            books.wordDestination = .fixed(unticked)
            #expect(await books.exportToWord() == .exported)
            #expect(try Self.exportedComments(unticked) == nil, "as the panel opens, without comments")

            let ticked = folder.appending(path: "Ticked.docx")
            books.wordDestination = WordDestination { _, options in
                WordDestination.accessory(options).rootView.options.comments = .include
                return ticked
            }
            #expect(await books.exportToWord() == .exported)
            let comments = try #require(try Self.exportedComments(ticked), "ticked, with comments")
            #expect(comments.contains(">Check the schedule.<"))

            let again = folder.appending(path: "Again.docx")
            books.wordDestination = .fixed(again)
            #expect(await books.exportToWord() == .exported)
            #expect(try Self.exportedComments(again) == nil, "the next export starts unticked again")

            #expect(await store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}
