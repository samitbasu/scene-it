import Foundation
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

            book.structureUndo.undo()
            #expect(book.book == before)
            book.structureUndo.redo()
            #expect(book.book.boneyard.isEmpty && book.book.deleted[0] == brother)

            store.saveNow()
            await eventually { book.status == .saved }
            let saved = String(decoding: try Data(contentsOf: url.layout.book), as: UTF8.self)
            #expect(try bookOnDisk(url) == book.book)
            #expect(!saved.contains("# Boneyard"))
            #expect(saved.hasSuffix(String(Self.deletedBlock.dropFirst("# Deleted\n\n".count))))
            #expect(saved.contains("# Deleted\n\n## The brother\nid: brother\n"))
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
