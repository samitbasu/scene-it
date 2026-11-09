import AppKit
import SceneItCore
import SceneItTestSupport
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
}
