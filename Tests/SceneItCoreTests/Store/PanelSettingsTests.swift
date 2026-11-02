import Foundation
import Testing

@testable import SceneItCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PanelSettingsTests {
    @Test func thePanelStateAndTabAreSavedInTheBookAndReopenTheSame() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            #expect(book.book.settings.rightPanelOpen == .open)
            #expect(book.book.settings.rightPanel == .comments)

            book.toggleRightPanel()
            book.showRightPanelTab(.tags)
            #expect(book.status == .unsaved)
            store.saveNow()
            await eventually { book.status == .saved }
            let saved = try bookOnDisk(url).settings
            #expect(saved.rightPanelOpen == .closed)
            #expect(saved.rightPanel == .tags)

            #expect(await store.closeBook() == .left)
            #expect(await store.open(url) == .opened)
            #expect(store.current?.book.settings.rightPanelOpen == .closed)
            #expect(store.current?.book.settings.rightPanel == .tags)
            store.current?.toggleRightPanel()
            #expect(store.current?.book.settings.rightPanelOpen == .open)
        }
    }

    @Test func choosingTheSameStateIsNotAnEdit() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            book.setRightPanel(.open)
            book.showRightPanelTab(.comments)
            #expect(book.status == .saved)
        }
    }

    @Test func aReadOnlyBookFollowsThePanelInMemoryOnly() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Held.sceneit")
            let holder = try BookPackage.create(at: url, title: "Held")
            let onDisk = try bookOnDisk(url)
            let fileSystem = FaultInjectingFileSystem(root: folder)
            let store = makeStore(in: folder, fileSystem: fileSystem)
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            let book = try #require(store.current)

            book.toggleRightPanel()
            book.showRightPanelTab(.notes)
            #expect(book.book.settings.rightPanelOpen == .closed)
            #expect(book.book.settings.rightPanel == .notes)
            #expect(book.status == .readOnly(.openElsewhere))
            #expect(await store.closeBook() == .left)
            #expect(try bookOnDisk(url) == onDisk)
            #expect(
                fileSystem.calls.filter(\.isMutation) == [.lock("Held.sceneit/.lock")],
                "only the lock attempt")
            withExtendedLifetime(holder) {}
        }
    }
}
