import AppKit
import Foundation
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// Questions wait until `answer` is called, so a test can watch the store while one is up.
private final class WaitingPrompts: StorePrompts {
    private(set) var titles: [String] = []
    private var pending: [CheckedContinuation<Void, Never>] = []

    func ask<Choice>(_ alert: WriterAlert<Choice>) async -> Choice {
        titles.append(alert.title)
        await withCheckedContinuation { pending.append($0) }
        return alert.choices[0]
    }

    func tell(_ notice: Notice) async {
        titles.append(notice.title)
    }

    func answer() {
        for continuation in pending { continuation.resume() }
        pending = []
    }
}

extension OneAtATime {
    /// These drive the app's own store (`BookController.shared`), so they run one at a time.
    @Suite(.serialized, .timeLimit(.minutes(1)))
    struct BookStoreIntegrationTests {
        /// The app's own store answers without the writer here; any question it asked was unexpected.
        func expectNoQuestions(sourceLocation: SourceLocation = #_sourceLocation) {
            let headless = BookController.shared.prompts as? HeadlessPrompts
            #expect(headless != nil, sourceLocation: sourceLocation)
            #expect(headless?.titles == [], sourceLocation: sourceLocation)
        }

        @Test func theTestHostKeepsBooksAwayFromTheWritersFiles() {
            let books = BookController.shared
            #expect(books.memory is TransientBookMemory)
            #expect(
                books.mirror.root.path(percentEncoded: false).hasPrefix(
                    FileManager.default.temporaryDirectory.path(percentEncoded: false)))
            #expect(books.mirror != BackupMirror.standard)
            #expect(books.store.current == nil, "the test host doesn't reopen the writer's last book")
        }

        @Test func theFileMenuHasNewOpenAndSave() {
            for title in [
                StoreWording.newBookMenuItem, StoreWording.openBookMenuItem, StoreWording.saveMenuItem,
            ] {
                #expect(menuItem(titled: title, in: NSApp.mainMenu) != nil, "\(title)")
            }
            #expect(menuItem(titled: StoreWording.saveMenuItem, in: NSApp.mainMenu)?.keyEquivalent == "s")
        }

        @Test func anEditReachesBookMdThroughAutosaveAndReopensTheSame() async throws {
            try await withTemporaryFolder { folder in
                let store = BookController.shared.store
                let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
                #expect(await store.create(at: url) == .created)
                let book = try #require(store.current)
                let scene = try #require(book.addScene(after: nil))
                await eventually { book.status == .saved }
                book.replaceBody(of: scene, with: [[Run("The tide came in.")], [], [Run("It went out.")]])
                #expect(book.status == .unsaved)
                await eventually { book.status == .saved }
                #expect(try bookOnDisk(url) == book.book)
                #expect(
                    try bookOnDisk(url).scenes.first?.body.map(\.text) == [
                        "The tide came in.", "", "It went out.",
                    ])
                let snapshots = try FileManager.default.contentsOfDirectory(
                    atPath: url.appending(path: "Backups").path(percentEncoded: false))
                #expect(snapshots.contains { $0.hasPrefix("book-") })

                let saved = book.book
                #expect(await store.closeBook() == .left)
                #expect(await store.open(url) == .opened)
                #expect(store.current?.book == saved)
                #expect(await store.closeBook() == .left)
                expectNoQuestions()
            }
        }

        /// The autosave timer runs on the main actor, and nothing here suspends between the edit and
        /// the menu, so a save running as the menu returns was started by the menu, not the timer.
        @Test func fileSaveSavesAtOnce() async throws {
            try await withTemporaryFolder { folder in
                let store = BookController.shared.store
                let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
                #expect(await store.create(at: url) == .created)
                let book = try #require(store.current)
                let scene = try #require(book.addScene(after: nil))
                await eventually { book.status == .saved }
                await eventually {
                    guard let menu = menuItem(titled: StoreWording.saveMenuItem, in: NSApp.mainMenu)?.menu
                    else {
                        return false
                    }
                    menu.delegate?.menuNeedsUpdate?(menu)
                    menu.update()
                    return menuItem(titled: StoreWording.saveMenuItem, in: NSApp.mainMenu)?.isEnabled == true
                }
                book.setTitle(of: scene, to: "Saved by the menu")
                #expect(book.status == .unsaved, "precondition: the edit waits for autosave")
                try perform(try #require(menuItem(titled: StoreWording.saveMenuItem, in: NSApp.mainMenu)))
                #expect(book.status == .saving, "the menu started the save in its own turn")
                await eventually { book.status == .saved }
                #expect(try bookOnDisk(url).scenes.first?.title == "Saved by the menu")
                #expect(await store.closeBook() == .left)
                expectNoQuestions()
            }
        }

        @Test func aBookAppKitAsksUsToOpenIsOpened() async throws {
            try await withTemporaryFolder { folder in
                let url = folder.appending(path: "From Finder.sceneit", directoryHint: .isDirectory)
                _ = try BookPackage.create(at: url, title: "From Finder")
                let delegate = try #require(NSApp.delegate)
                try #require(delegate.responds(to: #selector(NSApplicationDelegate.application(_:open:))))
                delegate.application?(NSApp, open: [url])
                let store = BookController.shared.store
                await eventually { store.current?.document.url.canonicalPath == url.canonicalPath }
                #expect(store.current?.isEditable == true)
                #expect(await store.closeBook() == .left)
                expectNoQuestions()
            }
        }

        @Test func ofSeveralBooksAppKitAsksUsToOpenTheFirstOpensAndTheWriterIsTold() async throws {
            try await withTemporaryFolder { folder in
                let urls = ["One", "Two"].map {
                    folder.appending(path: "\($0).sceneit", directoryHint: .isDirectory)
                }
                for url in urls {
                    _ = try BookPackage.create(at: url, title: url.deletingPathExtension().lastPathComponent)
                }
                let headless = try #require(BookController.shared.prompts as? HeadlessPrompts)
                let delegate = try #require(NSApp.delegate)
                delegate.application?(NSApp, open: urls)
                let store = BookController.shared.store
                await eventually { headless.titles.count == 1 }
                #expect(store.current?.document.url.canonicalPath == urls[0].canonicalPath)
                #expect(headless.takeTitles() == ["Scene It opens one book at a time."])
                #expect(store.recentBooks.prefix(2).map(\.canonicalPath) == urls.map(\.canonicalPath))
                #expect(await store.closeBook() == .left)
                expectNoQuestions()
            }
        }

        @Test func anExternalWriteThenAnEditReachesChangedOnDisk() async throws {
            try await withTemporaryFolder { folder in
                let prompts = WaitingPrompts()
                let store = BookController(role: .testHost, prompts: prompts).store
                let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
                #expect(await store.create(at: url) == .created)
                let book = try #require(store.current)
                let scene = try #require(book.addScene(after: nil))
                await eventually { book.status == .saved }

                var theirs = try bookOnDisk(url)
                theirs.title = "Their version"
                try BookFormat.serialize(theirs).write(to: url.appending(path: "book.md"), options: .atomic)
                book.setTitle(of: scene, to: "My version")
                store.saveNow()
                await eventually { prompts.titles == ["This book was changed by another program."] }
                guard case .changedOnDisk = book.status else {
                    Issue.record("status is \(book.status)")
                    return
                }
                #expect(try bookOnDisk(url) == theirs, "nothing was saved over their version")

                prompts.answer()
                await eventually { book.status == .saved }
                #expect(try bookOnDisk(url) == book.book)
                #expect(await store.closeBook() == .left)
            }
        }
    }
}
