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
            #expect(books.mainWindowChrome.wordExport == nil)
            let url = folder.appending(path: "Tide.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            book.setTitle(of: scene, to: "The ferry")
            book.replaceBody(of: scene, with: [[Run("The ferry left at "), Run("dawn", styles: [.italic])]])
            book.select(scene)
            await eventually { books.mainWindowChrome.wordExport?.book === book }
            let flow = try #require(books.mainWindowChrome.wordExport, "precondition: the window's flow")
            #expect(flow.scene?.id == scene)
            await eventually { Self.exportToWordIsEnabled() == true }
            #expect(Self.exportToWordIsEnabled() == true)

            let destination = folder.appending(path: "The ferry.docx")
            books.wordDestination = .fixed(destination)
            defer { books.wordDestination = .nowhere }

            #expect(await flow.begin() == .exported)

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
            await eventually { books.mainWindowChrome.wordExport?.book === book }
            let flow = try #require(books.mainWindowChrome.wordExport, "precondition: the window's flow")
            defer { books.wordDestination = .nowhere }

            let unticked = folder.appending(path: "Unticked.docx")
            books.wordDestination = .fixed(unticked)
            #expect(await flow.begin() == .exported)
            #expect(try Self.exportedComments(unticked) == nil, "as the panel opens, without comments")

            let ticked = folder.appending(path: "Ticked.docx")
            books.wordDestination = WordDestination { _, options in
                WordDestination.accessory(options).rootView.options.comments = .include
                return ticked
            }
            #expect(await flow.begin() == .exported)
            let comments = try #require(try Self.exportedComments(ticked), "ticked, with comments")
            #expect(comments.contains(">Check the schedule.<"))

            let again = folder.appending(path: "Again.docx")
            books.wordDestination = .fixed(again)
            #expect(await flow.begin() == .exported)
            #expect(try Self.exportedComments(again) == nil, "the next export starts unticked again")

            #expect(await store.closeBook() == .left)
            expectNoQuestions()
        }
    }

    /// File → Export to Word… and the toolbar's Export to Word go through the window's one
    /// `WordExportFlow`, so they export the scene the window shows and are enabled together:
    /// never while a rail sheet, File a Copy's dialog, Export as SceneIt's chooser or the print
    /// dialog is up, as Print… isn't.
    ///
    /// The toolbar's button is drawn by SwiftUI and shows no enabled state or action here (its
    /// hosting view has no controls or accessibility children in the test host), and it can't be
    /// pressed without input. So this checks what it acts on: the main window builds its toolbar
    /// with the flow it registers in `MainWindowChrome`, and that's the flow the menu uses.
    @Test func theMenuAndTheToolbarExportTheWindowsSceneAndAgreeOnWhen() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            let store = books.store
            try #require(store.isChoosing, "precondition: the start screen")
            let url = folder.appending(path: "Tide.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            book.setTitle(of: scene, to: "The ferry")
            book.replaceBody(of: scene, with: [[Run("The ferry left at dawn.")]])
            book.select(scene)
            let window = try #require(books.mainWindow, "precondition: the app's main window")
            await eventually {
                window.toolbar?.isVisible == true && books.mainWindowChrome.wordExport?.book === book
            }
            #expect(window.toolbar?.items.contains { $0.label == WindowWording.exportToWord } == true)
            let flow = try #require(books.mainWindowChrome.wordExport, "precondition: the window's flow")
            try #require(flow.scene?.id == scene, "precondition: the window's open scene")
            let desks = subviewTree(of: window.contentView).compactMap { $0 as? DeskView }
            let keys = try #require(desks.compactMap(\.keys).first, "precondition: the page's keys")
            try #require(
                keys.filing.book === book && keys.export.book === book, "precondition: the window's dialogs")
            defer { books.wordDestination = .nowhere }

            @MainActor func expectAgreement(_ state: Availability, _ why: Testing.Comment) async {
                await eventually { Self.exportToWordIsEnabled() == state.isEnabled }
                #expect(Self.exportToWordIsEnabled() == state.isEnabled, why)
                #expect(flow.canBegin == state.isEnabled, why)
            }

            await expectAgreement(.enabled, "the page shows")
            keys.mode.wrappedValue = .scenes
            await expectAgreement(.disabled, "the Scenes sheet covers the page")
            let refused = folder.appending(path: "Refused.docx")
            books.wordDestination = .fixed(refused)
            #expect(await flow.begin() == nil, "begin does nothing then")
            #expect(!FileManager.default.fileExists(atPath: refused.path(percentEncoded: false)))
            keys.mode.wrappedValue = .search
            await expectAgreement(.disabled, "the Search sheet covers the page")
            keys.mode.wrappedValue = .fileCabinet
            await expectAgreement(.disabled, "the File Cabinet sheet covers the page")
            keys.mode.wrappedValue = .page
            await expectAgreement(.enabled, "the page shows again")

            keys.filing.begin()
            await expectAgreement(.disabled, "File a Copy's dialog is up")
            keys.filing.cancel()
            await expectAgreement(.enabled, "the dialog went")
            keys.export.begin()
            await expectAgreement(.disabled, "Export as SceneIt's chooser is up")
            keys.export.cancel()
            await expectAgreement(.enabled, "the chooser went")

            let recorded = RecordedPrints()
            let present = PrintFlow.present
            PrintFlow.present = { operation, window, flow in
                recorded.shown.append((operation, window, flow))
            }
            defer { PrintFlow.present = present }
            let printing = try #require(books.mainWindowChrome.printing)
            // The chooser's sheet can still be on its way out, and Print… won't show over a sheet.
            await eventually { printing.window === window && window.attachedSheet == nil }
            printing.begin()
            try #require(recorded.shown.count == 1, "precondition: the print dialog is up")
            await expectAgreement(.disabled, "the print dialog is up")
            printing.finished()
            await expectAgreement(.enabled, "the print dialog went")

            let destination = folder.appending(path: "The ferry.docx")
            books.wordDestination = .fixed(destination)
            let item = try #require(menuItem(titled: WordExportWording.menuItem, in: NSApp.mainMenu))
            try perform(item)
            await eventually {
                FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
            }
            let read = try NSAttributedString(
                url: destination, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil)
            #expect(read.string.hasPrefix("The ferry\nThe ferry left at dawn."), "the window's open scene")

            #expect(await store.closeBook() == .left)
            await eventually {
                books.mainWindowChrome.wordExport == nil && Self.exportToWordIsEnabled() == false
            }
            #expect(Self.exportToWordIsEnabled() == false, "no scene to export on the start screen")
            expectNoQuestions()
        }
    }

    enum Availability {
        case enabled, disabled

        var isEnabled: Bool {
            self == .enabled
        }
    }
}
