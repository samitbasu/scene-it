import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// Export as SceneIt… in the app's own window (ADR 0029): File → Export as SceneIt… puts up the
/// chooser as the window's sheet, and its Export… writes the review copy where the destination
/// says. Two steps are the app's alone. The save panel: the test host's destination names a file in
/// the test's temporary folder instead, and by default none. And the menu item itself, which
/// reaches the window's flow through SwiftUI's focused value, so only while the window is key:
/// the test host never takes the key window from the owner's apps, so these tests start from
/// what the item runs, `ExportFlow.begin()`.
extension BookStoreIntegrationTests {
    @Test func theFileMenuHasExportAsSceneItAfterFileACopy() throws {
        let item = try #require(menuItem(titled: ExportWording.menuItem, in: NSApp.mainMenu))
        let menu = try #require(item.menu)
        let filing = try #require(menuItem(titled: ArchiveWording.menuItem, in: menu))
        #expect(menu.index(of: item) == menu.index(of: filing) + 1)
        #expect(item.keyEquivalent.isEmpty, "no shortcut")
    }

    /// Three story scenes, the second with notes, a tag and a colored word, and one in the
    /// Boneyard.
    private static func sample() -> Book {
        let time = Timestamp(.now, in: .current)
        func scene(_ id: String, _ title: String, _ body: [Paragraph]) -> BookScene {
            BookScene(id: SceneID(rawValue: id), modified: time, title: SceneTitle(title), body: body)
        }
        var middle = scene(
            "s2", "Arrival", [[Run("Nobody met "), Run("her", styles: [.bold], color: .red), Run(".")]])
        middle.notes = [[Run("A private note.")]]
        middle.tags = ["secret-tag"]
        return Book(
            title: "Tide 79",
            scenes: [
                scene("s1", "Dawn", [[Run("The ferry left at "), Run("dawn", styles: [.italic]), Run(".")]]),
                middle,
                scene("s3", "Dusk", [[Run("The gulls came home.")]]),
            ],
            boneyard: [scene("cut", "Cut scene", [[Run("Never sent.")]])])
    }

    /// Opens the sample in the app's own window; the chooser's flow, from the window's keys.
    @MainActor
    private func openSample(in folder: URL, _ books: BookController) async throws -> (URL, NSWindow) {
        let url = folder.appending(path: "Tide 79.sceneit", directoryHint: .isDirectory)
        #expect(await books.store.create(at: url) == .created)
        #expect(await books.store.closeBook() == .left)
        try BookFormat.serialize(Self.sample()).write(to: url.appending(path: "book.md"), options: .atomic)
        #expect(await books.store.open(url) == .opened)
        let window = try #require(books.mainWindow, "precondition: the app's main window")
        return (url, window)
    }

    @MainActor
    private func keys(in window: NSWindow) -> WindowKeys? {
        subviewTree(of: window.contentView).lazy.compactMap { ($0 as? DeskView)?.keys }.first
    }

    @MainActor
    private func flow(in window: NSWindow) -> ExportFlow? {
        keys(in: window)?.export
    }

    @Test func exportAsSceneItFromTheFileMenuWritesTheChosenStoryScenes() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let destination = folder.appending(path: "Tide 79 for review.md")
            books.exportDestination = .fixed(destination)
            defer { books.exportDestination = .nowhere }
            let (url, window) = try await openSample(in: folder, books)
            let bookBytes = try Data(contentsOf: url.appending(path: "book.md"))
            await eventually { self.flow(in: window) != nil }
            let flow = try #require(flow(in: window))
            #expect(flow.canBegin(in: books.store))

            flow.begin()

            await eventually { window.attachedSheet != nil }
            #expect(window.attachedSheet != nil, "the chooser is the window's sheet")
            let choice = try #require(flow.choice)
            #expect(choice.rows.map(\.id.rawValue) == ["s1", "s2", "s3"], "story scenes only: no Boneyard")
            #expect(choice.allTicked)
            #expect(!flow.canBegin(in: books.store), "not again while it's up")
            flow.click(SceneID(rawValue: "s3"), .single)

            let result = await flow.confirm(in: books.store)

            #expect(result == .exported)
            await eventually { window.attachedSheet == nil }
            #expect(window.attachedSheet == nil, "the chooser closed")
            let parsed = ReviewCopyFormat.parse(
                try Data(contentsOf: destination), opened: Timestamp(.now, in: .current))
            guard case .reviewCopy = parsed.recognition else {
                Issue.record("not a review copy: \(parsed.recognition)")
                return
            }
            #expect(parsed.parsed.newEntries.isEmpty)
            #expect(parsed.parsed.book.title == "Tide 79")
            #expect(parsed.parsed.book.scenes.map(\.id.rawValue) == ["s1", "s2"])
            let text = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
            #expect(text.contains("The ferry left at *dawn*.") && text.contains("Nobody met **her**."))
            for excluded in ["A private note", "secret-tag", "Cut scene", "Never sent", "Dusk", "red"] {
                #expect(!text.contains(excluded), "\(excluded) leaked")
            }
            #expect(
                try Data(contentsOf: url.appending(path: "book.md")) == bookBytes, "the book is untouched")
            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }

    @Test func escClosesTheChooserAndACancelledPanelWritesNothing() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            try #require(
                await books.exportDestination.choose("x") == nil,
                "precondition: the test host's destination is nowhere")
            let (_, window) = try await openSample(in: folder, books)
            await eventually { self.flow(in: window) != nil }
            let flow = try #require(flow(in: window))
            let keys = try #require(keys(in: window))

            flow.begin()
            await eventually { window.attachedSheet != nil }
            #expect(keys.escapeContext.dialog == .open)
            #expect(keys.escape(from: .keyEquivalent) == .handled)
            #expect(flow.choice == nil, "Esc closed the chooser")
            await eventually { window.attachedSheet == nil }

            flow.begin()
            let before = try FileManager.default.contentsOfDirectory(
                atPath: folder.path(percentEncoded: false))
            #expect(await flow.confirm(in: books.store) == nil, "the panel was cancelled")
            #expect(flow.choice == nil)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                    == before)
            await eventually { window.attachedSheet == nil }

            flow.begin()
            flow.choice?.untickAll()
            #expect(await flow.confirm(in: books.store) == nil, "nothing ticked: Export… does nothing")
            #expect(flow.choice != nil, "and the chooser stays up")
            flow.cancel()
            await eventually { window.attachedSheet == nil }
            #expect(await books.store.closeBook() == .left)
            expectNoQuestions()
        }
    }
}
