import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// Adding a scene through the store (PLAN §7.2, §8.6, #28): one change on `structureUndo`, named
/// "New Scene", whose undo takes the scene out and reopens the scene that was open. A scene the
/// writer wrote in goes to the Deleted section rather than away (ADR 0041), and redo brings it
/// back from there.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AddSceneTests {
    /// A book with two scenes, the first open, and no structure history.
    private func withTwoScenes(
        _ test: (TestStore, OpenBook<ManualClock>, [SceneID], URL) async throws -> Void
    ) async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let first = try #require(book.addScene(after: nil))
            let second = try #require(book.addScene(after: first))
            book.select(first)
            book.structureUndo.removeAllActions()
            try await test(store, book, [first, second], url)
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func addingInsertsAfterTheSceneOpensItAndIsOneUndoableStep() async throws {
        try await withTwoScenes { _, book, scenes, _ in
            let before = book.book
            let added = try #require(book.addScene(after: scenes[0]))
            #expect(book.book.scenes.map(\.id) == [scenes[0], added, scenes[1]])
            #expect(book.openScene == added)
            #expect(book.structureUndo.undoActionName == ScenesWording.newSceneUndoName)

            book.structureUndo.undo()
            #expect(book.book == before, "taken out, leaving nothing behind")
            #expect(book.openScene == scenes[0], "the scene that was open opens again")
            #expect(book.structureUndo.redoActionName == ScenesWording.newSceneUndoName)

            book.structureUndo.redo()
            #expect(book.book.scenes.map(\.id) == [scenes[0], added, scenes[1]], "the same scene, in place")
            #expect(book.openScene == added)
            book.structureUndo.undo()
            #expect(book.book == before)
        }
    }

    @Test func addingAfterNothingOrAnUnknownSceneAddsAtTheEnd() async throws {
        try await withTwoScenes { _, book, scenes, _ in
            let end = try #require(book.addScene(after: nil))
            let unknown = try #require(book.addScene(after: SceneID(rawValue: "nowhere")))
            #expect(book.book.scenes.map(\.id) == scenes + [end, unknown])
        }
    }

    @Test func undoingAnAddWhileAnotherSceneIsOpenLeavesThatSceneOpen() async throws {
        try await withTwoScenes { _, book, scenes, _ in
            let added = try #require(book.addScene(after: nil))
            book.select(scenes[1])
            book.structureUndo.undo()
            #expect(!book.book.scenes.contains { $0.id == added })
            #expect(book.openScene == scenes[1])
        }
    }

    /// With no scene open before the add, undoing it leaves none open.
    @Test func undoingTheFirstSceneOfAnEmptyBookLeavesNoSceneOpen() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            _ = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            try #require(book.openScene == nil, "precondition: an empty book")
            #expect(book.addScene(after: nil) != nil)
            book.structureUndo.undo()
            #expect(book.book.scenes.isEmpty && book.openScene == nil)
            #expect(await store.closeBook() == .left)
        }
    }

    /// Trust first: undoing an add never takes away words. The scene goes to the Deleted
    /// section, which the file keeps and the app never shows; redo brings it back whole.
    @Test func undoingTheAddOfASceneWithWordsKeepsItInTheDeletedSection() async throws {
        try await withTwoScenes { store, book, scenes, url in
            let added = try #require(book.addScene(after: scenes[1]))
            book.setTitle(of: added, to: "The lighthouse")
            book.replaceBody(of: added, with: [[Run("Old Tomas kept the lamp lit.")]])
            let written = try #require(book.book.scene(added))

            book.structureUndo.undo()
            #expect(book.book.scenes.map(\.id) == scenes)
            #expect(book.book.scene(added) == nil, "the writer no longer sees it")
            #expect(book.book.deleted == [written], "the file keeps it")
            store.saveNow()
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).deleted == [written])

            book.structureUndo.redo()
            #expect(book.book.scenes.map(\.id) == scenes + [added])
            #expect(book.book.scene(added) == written)
            #expect(book.book.deleted.isEmpty)
            #expect(book.openScene == added)
        }
    }

    @Test func undoingTheAddOfABlankSceneLeavesNothingInTheFile() async throws {
        try await withTwoScenes { store, book, scenes, url in
            let added = try #require(book.addScene(after: nil))
            book.replaceBody(of: added, with: [[]])
            book.structureUndo.undo()
            #expect(book.book.deleted.isEmpty)
            store.saveNow()
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes.map(\.id) == scenes)
        }
    }

    @Test func eachPartTheWriterFillsMakesASceneNotBlank() {
        let blank = BookScene(id: SceneID(rawValue: "s"), modified: Timestamp(.now, in: .gmt), title: "")
        #expect(blank.isBlank)
        var empty = blank
        empty.body = [[], []]
        empty.notes = [[]]
        #expect(empty.isBlank)
        let filled: [(inout BookScene) -> Void] = [
            { $0.title = "T" }, { $0.tags = ["t"] }, { $0.body = [[Run("x")]] }, { $0.notes = [[Run("x")]] },
            { $0.comments = [tooEarlyComment] },
            { $0.errors = [ErrorEntry(.line, "kept")] },
        ]
        for fill in filled {
            var scene = blank
            fill(&scene)
            #expect(!scene.isBlank)
        }
    }

    @Test func aReadOnlyBookRefusesToAdd() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            #expect(await store.closeBook() == .left)
            #expect(book.addScene(after: nil) == nil, "a detached book takes no edits")
            #expect(!book.structureUndo.canUndo)
            withExtendedLifetime(url) {}
        }
    }
}

private let tooEarlyComment = Comment(
    id: CommentID(rawValue: "c1"), color: .purple, text: "Too early?", created: Timestamp(.now, in: .gmt))
