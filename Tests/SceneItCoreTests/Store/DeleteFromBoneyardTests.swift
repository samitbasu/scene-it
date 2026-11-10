import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// ADR 0031 through the open book: deleting a Boneyard scene moves it to the Deleted section as
/// one undoable change, and the save writes it there, leaving the scenes already deleted as
/// they were, byte for byte.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DeleteFromBoneyardTests {
    static let brother = SceneID(rawValue: "brother")

    static let deletedBlock = """
        # Deleted

        ## The dream
        id: dream
        modified: 2026-01-01T00:00:00+00:00
        tags: hand, made

        Mara *dreamed* of the harbor.

        ### Notes
        Too much like chapter 2.

        ### Comments
        - c1 | red | 2026-01-01T00:00:00+00:00 | c0-4 | "Mara" | Who?

        ### Unparsed
        - [line] kept since an earlier session

        """

    static let text = """
        ---
        title: Novel
        format: 2
        ---

        ## The ferry
        id: ferry
        modified: 2026-01-01T00:00:00+00:00

        Mara took the ferry.

        # Boneyard

        ## The brother
        id: brother
        modified: 2026-01-01T00:00:00+00:00

        Pieter painted the boat.


        """ + deletedBlock

    @Test func deletingIsOneUndoableChangeThatSavesToTheDeletedSection() async throws {
        try await withTemporaryFolder { folder in
            let url = try package(holding: Data(Self.text.utf8), in: folder)
            let store = makeStore(in: folder, parseDefaults: fixedDefaults)
            _ = await store.open(url)
            let book = try #require(store.current)
            #expect(book.isEditable && book.status == .saved, "precondition: opens for editing")
            #expect(
                BookFormat.serialize(book.book) == Data(Self.text.utf8), "precondition: the file is canonical"
            )
            let before = book.book
            let brother = try #require(before.boneyard.first)
            book.select(Self.brother)

            #expect(!book.deleteFromBoneyard(before.scenes[0].id), "a story scene isn't in the Boneyard")
            #expect(book.book == before && !book.structureUndo.canUndo)

            #expect(book.deleteFromBoneyard(Self.brother))
            #expect(book.status == .unsaved, "autosave heard in the same turn")
            #expect(book.book.boneyard.isEmpty)
            #expect(book.book.deleted.map(\.id.rawValue) == ["brother", "dream"])
            #expect(book.book.deleted[0] == brother)
            #expect(book.openScene == nil, "the open scene was deleted, so none is open")
            #expect(book.location == .noScene)
            #expect(!book.deleteFromBoneyard(Self.brother), "it's deleted already")

            #expect(book.structureUndo.undoActionName == BoneyardWording.deleteUndoName)
            book.structureUndo.undo()
            #expect(book.book == before)
            #expect(!book.structureUndo.canUndo && book.structureUndo.canRedo)
            #expect(book.structureUndo.redoActionName == BoneyardWording.deleteUndoName)
            book.structureUndo.redo()
            #expect(book.book.boneyard.isEmpty && book.book.deleted[0] == brother)
            #expect(book.structureUndo.canUndo && !book.structureUndo.canRedo)

            store.saveNow()
            await whenObserved { book.status == .saved }
            let saved = String(decoding: try Data(contentsOf: url.layout.book), as: UTF8.self)
            #expect(try bookOnDisk(url) == book.book)
            #expect(!saved.contains("# Boneyard"))
            #expect(saved.hasSuffix(String(Self.deletedBlock.dropFirst("# Deleted\n\n".count))))
            #expect(saved.contains("# Deleted\n\n## The brother\nid: brother\n"))
            #expect(await store.closeBook() == .left)
        }
    }

    private func open(_ text: String, in folder: URL) async throws -> (TestStore, OpenBook<ManualClock>, URL)
    {
        let url = try package(holding: Data(text.utf8), in: folder)
        let store = makeStore(in: folder, parseDefaults: fixedDefaults)
        _ = await store.open(url)
        let book = try #require(store.current)
        try #require(book.isEditable && book.status == .saved, "precondition: opens for editing")
        return (store, book, url)
    }

    @Test func undoingADeleteSavesTheBookAsItWas() async throws {
        try await withTemporaryFolder { folder in
            let (store, book, url) = try await open(Self.text, in: folder)
            #expect(book.deleteFromBoneyard(Self.brother))
            book.structureUndo.undo()
            #expect(book.status == .unsaved, "the undo is an edit to save")
            store.saveNow()
            await whenObserved { book.status == .saved }
            #expect(try Data(contentsOf: url.layout.book) == Data(Self.text.utf8))
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func deletingAnotherSceneLeavesTheOpenSceneOpen() async throws {
        try await withTemporaryFolder { folder in
            let (store, book, _) = try await open(Self.text, in: folder)
            let ferry = SceneID(rawValue: "ferry")
            try #require(book.openScene == ferry, "precondition: the story's first scene is open")
            #expect(book.deleteFromBoneyard(Self.brother))
            #expect(book.openScene == ferry)
            #expect(await store.closeBook() == .left)
        }
    }

    /// An Errors-tab Fix can change a deleted scene's id; undoing the delete still finds it.
    @Test func undoFindsADeletedSceneWhoseIDAFixChanged() async throws {
        try await withTemporaryFolder { folder in
            let text = Self.text.replacingOccurrences(
                of: "Pieter painted the boat.\n",
                with: "Pieter painted the boat.\n\n### Unparsed\n- [metadata] id: renamed\n")
            let (store, book, _) = try await open(text, in: folder)
            let renamed = SceneID(rawValue: "renamed")
            #expect(book.deleteFromBoneyard(Self.brother))
            let ref = try #require(
                book.book.errorGroups.first { $0.owner == .scene(Self.brother) }?.refs.first)
            #expect(book.repairError(ref, as: "id: renamed") == .repaired)
            try #require(book.book.deleted.first?.id == renamed, "precondition: the Fix changed the id")

            book.structureUndo.undo()
            #expect(book.book.boneyard.map(\.id) == [renamed])
            #expect(!book.book.deleted.contains { $0.id == renamed })
            book.structureUndo.redo()
            #expect(book.book.boneyard.isEmpty && book.book.deleted.first?.id == renamed)

            book.errorsUndo.undo()
            #expect(book.book.deleted.first?.id == Self.brother, "the Fix's own undo puts the old id back")
            book.structureUndo.undo()
            #expect(book.book.boneyard.map(\.id) == [Self.brother])
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func aReadOnlyBookRefusesToDelete() async throws {
        try await withTemporaryFolder { folder in
            let damaged = Self.text.replacingOccurrences(of: "id: ferry", with: "id: ferry boat")
            let url = try package(holding: Data(damaged.utf8), in: folder)
            let store = makeStore(
                in: folder, prompts: ScriptedPrompts([ReadOnlyChoice.keepReadOnly]),
                parseDefaults: fixedDefaults)
            _ = await store.open(url)
            let book = try #require(store.current)
            try #require(!book.isEditable, "precondition: a repaired book opens read-only")
            try #require(
                book.book.boneyard.contains { $0.id == Self.brother }, "precondition: the scene is there")
            #expect(!book.deleteFromBoneyard(Self.brother))
            #expect(book.book.boneyard.contains { $0.id == Self.brother })
            #expect(await store.closeBook() == .left)
        }
    }
}
