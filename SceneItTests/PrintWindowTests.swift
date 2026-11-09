import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// Print… in the app's own window (PLAN §10.1): File → Print… and the toolbar's Print go through
/// the window's one `PrintFlow`, so both print the book the window shows, as a sheet on that
/// window; and Print is unavailable while the print dialog, a rail sheet or a dialog is up. The
/// dialog is recorded instead of shown, so nothing is printed.
extension OneAtATime.BookStoreIntegrationTests {
    @MainActor
    static func printItem() -> NSMenuItem? {
        OneBookRenders.fileMenu().items.first { $0.title == PrintWording.menuItem }
    }

    @MainActor
    final class RecordedPrints {
        var shown: [(operation: NSPrintOperation, window: NSWindow, flow: PrintFlow)] = []
    }

    @Test func theMenuAndTheToolbarPrintTheWindowsBookOnItsWindow() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let url = folder.appending(path: "Tide.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            let book = try #require(books.store.current)
            let scene = try #require(book.addScene(after: nil))
            book.setTitle(of: scene, to: "The ferry")
            book.select(scene)
            let window = try #require(books.mainWindow, "precondition: the app's main window")
            await eventually { window.toolbar?.isVisible == true }

            let recorded = RecordedPrints()
            let present = PrintFlow.present
            PrintFlow.present = { operation, window, flow in recorded.shown.append((operation, window, flow))
            }
            defer { PrintFlow.present = present }

            await eventually { Self.printItem()?.isEnabled == true }
            let item = try #require(menuItem(titled: PrintWording.menuItem, in: NSApp.mainMenu))
            try perform(item)
            await eventually { recorded.shown.count == 1 }
            let fromMenu = try #require(recorded.shown.first, "the menu showed the dialog")
            #expect(fromMenu.window === window, "a sheet on the book's own window")
            #expect(fromMenu.flow.book === book, "the book the window shows")
            #expect((fromMenu.operation.view as? ManuscriptPrintView) != nil)
            await eventually { Self.printItem()?.isEnabled == false }
            #expect(Self.printItem()?.isEnabled == false, "no second dialog while one is up")
            fromMenu.flow.finished()
            await eventually { Self.printItem()?.isEnabled == true }

            // The toolbar's button is drawn by SwiftUI and can't be pressed here without input, so
            // this checks what it acts on: `BookWindow` builds its toolbar with the flow it reports
            // its window to, and that's the flow the menu used.
            #expect(window.toolbar?.items.contains { $0.label == WindowWording.print } == true)
            let registered = try #require(books.mainWindowChrome.printing)
            #expect(registered === fromMenu.flow)
            #expect(registered.window === window, "the window's own flow, which its toolbar holds")

            let desks = subviewTree(of: window.contentView).compactMap { $0 as? DeskView }
            let keys = try #require(desks.compactMap(\.keys).first, "precondition: the page's keys")
            await eventually { Self.printItem()?.isEnabled == true }
            keys.mode.wrappedValue = .scenes
            await eventually { Self.printItem()?.isEnabled == false }
            #expect(Self.printItem()?.isEnabled == false, "not while the Scenes sheet covers the page")
            #expect(!fromMenu.flow.canBegin)
            fromMenu.flow.begin()
            #expect(recorded.shown.count == 1, "begin does nothing then")
            keys.mode.wrappedValue = .page
            await eventually { Self.printItem()?.isEnabled == true }

            #expect(await books.store.closeBook() == .left)
            await eventually { Self.printItem()?.isEnabled == false }
            expectNoQuestions()
        }
    }
}
