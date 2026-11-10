import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// Moving, cutting and restoring scenes through the open book (PLAN §7.2, §7.3, §8.6): each is one
/// step on `structureUndo`, named for what it did, and a cut scene keeps everything it holds
/// through the cut, the restore and the file.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SceneChangeTests {
    static let ferry = SceneID(rawValue: "ferry")
    static let letter = SceneID(rawValue: "letter")
    static let market = SceneID(rawValue: "market")
    static let brother = SceneID(rawValue: "brother")

    /// The letter holds a note, a comment, tags and an error entry, all of which a cut and a
    /// restore must keep.
    static let text = """
        ---
        title: Novel
        format: 2
        ---

        ## The ferry
        id: ferry
        modified: 2026-01-01T00:00:00+00:00

        Mara took the ferry.

        ## The letter
        id: letter
        modified: 2026-01-01T00:00:00+00:00
        tags: mother, clue

        He read it *twice*.

        ### Notes
        Move this earlier?

        ### Comments
        - c1 | red | 2026-01-01T00:00:00+00:00 | c0-2 | "He" | Who is he?

        ### Unparsed
        - [line] kept since an earlier session

        ## Market day
        id: market
        modified: 2026-01-01T00:00:00+00:00

        Goats and gossip.

        # Boneyard

        ## The brother
        id: brother
        modified: 2026-01-01T00:00:00+00:00

        Pieter painted the boat.

        """

    private func withBook(
        _ text: String = Self.text,
        _ test: (TestStore, OpenBook<ManualClock>, URL) async throws -> Void
    ) async throws {
        try await withTemporaryFolder { folder in
            let url = try package(holding: Data(text.utf8), in: folder)
            let store = makeStore(in: folder, parseDefaults: fixedDefaults)
            _ = await store.open(url)
            let book = try #require(store.current)
            try #require(book.isEditable && book.status == .saved, "precondition: opens for editing")
            try #require(
                BookFormat.serialize(book.book) == Data(text.utf8), "precondition: the file is canonical")
            try await test(store, book, url)
            #expect(await store.closeBook() == .left)
        }
    }

    private func save(_ store: TestStore, _ book: OpenBook<ManualClock>) async {
        store.saveNow()
        await whenObserved { book.status == .saved }
    }

    @Test func eachChangeIsOneNamedUndoableStep() async throws {
        try await withBook { store, book, url in
            let before = book.book
            let changes: [SceneChange] = [
                .move(Self.market, to: .before(Self.ferry)), .cut(Self.letter),
                .restore(Self.brother, to: .before(Self.ferry)),
            ]
            for change in changes {
                let unchanged = book.book
                #expect(book.change(change))
                #expect(book.status == .unsaved, "autosave heard in the same turn")
                #expect(book.structureUndo.undoActionName == ScenesWording.undoName(of: change))
                let changed = book.book
                book.structureUndo.undo()
                #expect(book.book == unchanged)
                #expect(book.structureUndo.redoActionName == ScenesWording.undoName(of: change))
                book.structureUndo.redo()
                #expect(book.book == changed)
            }
            #expect(book.book.scenes.map(\.id) == [Self.market, Self.brother, Self.ferry])
            #expect(book.book.boneyard.map(\.id) == [Self.letter])
            #expect(
                book.wordCounts.manuscript(of: book.book).words == 11, "3 + 4 + 4: the letter is left out")
            await save(store, book)
            let onDisk = try bookOnDisk(url)
            #expect(onDisk == book.book)

            for _ in changes { book.structureUndo.undo() }
            #expect(book.book == before)
            await save(store, book)
            let saved = try Data(contentsOf: url.layout.book)
            #expect(saved == Data(Self.text.utf8), "byte for byte")
        }
    }

    /// The acceptance test: a cut and a restore keep the scene's notes, comments, tags and error
    /// entries, in memory and in the file.
    @Test func cutAndRestoreKeepNotesCommentsAndTags() async throws {
        try await withBook { store, book, url in
            let letter = try #require(book.book.scene(Self.letter))
            try #require(
                !letter.notes.isEmpty && !letter.comments.isEmpty && !letter.tags.isEmpty
                    && !letter.errors.isEmpty, "precondition: the letter holds all of them")

            #expect(book.change(.cut(Self.letter)))
            #expect(book.book.boneyard.first == letter)
            await save(store, book)
            let saved = String(decoding: try Data(contentsOf: url.layout.book), as: UTF8.self)
            let boneyard = try #require(saved.range(of: "# Boneyard\n"))
            let cut = try #require(saved.range(of: "## The letter\n"))
            #expect(boneyard.upperBound <= cut.lowerBound, "written in the Boneyard")
            let onDisk = try bookOnDisk(url)
            #expect(onDisk.boneyard.first == letter)

            #expect(book.change(.restore(Self.letter, to: .before(Self.market))))
            #expect(book.book.scenes.map(\.id) == [Self.ferry, Self.letter, Self.market])
            #expect(book.book.scene(Self.letter) == letter)
            await save(store, book)
            let restored = try Data(contentsOf: url.layout.book)
            #expect(restored == Data(Self.text.utf8), "the file as it was")
        }
    }

    @Test func theOpenSceneStaysOpenWhereverItGoes() async throws {
        try await withBook { _, book, _ in
            book.select(Self.letter)
            #expect(book.change(.cut(Self.letter)))
            #expect(book.openScene == Self.letter)
            let letter = try #require(book.book.scene(Self.letter))
            #expect(book.location == .boneyard(letter))
            #expect(CurrentSceneMark(book.location) == .badge(WindowWording.boneyardBadge))
            #expect(book.change(.restore(Self.letter, to: .end)))
            #expect(book.location == .story(letter, number: 3, of: 3))
        }
    }

    @Test func aChangeThatDoesNothingOrDoesntApplyIsNoStep() async throws {
        try await withBook { _, book, _ in
            let before = book.book
            #expect(!book.change(.move(Self.ferry, to: .before(Self.letter))), "already there")
            #expect(!book.change(.move(Self.market, to: .end)), "already there")
            #expect(!book.change(.cut(Self.brother)), "cut already")
            #expect(!book.change(.restore(Self.ferry, to: .end)), "not in the Boneyard")
            #expect(!book.change(.move(Self.brother, to: .end)), "not in the story")
            #expect(!book.change(.move(Self.ferry, to: .before(Self.brother))), "a slot in the Boneyard")
            #expect(book.book == before && !book.structureUndo.canUndo)
            #expect(book.status == .saved)
        }
    }

    /// Deleting a scene that was cut, then undoing both, puts it back in the story.
    @Test func cutThenDeleteUndoesBackIntoTheStory() async throws {
        try await withBook { _, book, _ in
            let before = book.book
            book.select(Self.letter)
            #expect(book.change(.cut(Self.letter)))
            #expect(book.deleteFromBoneyard(Self.letter))
            #expect(book.openScene == nil && book.location == .noScene, "the page shows no scene")
            #expect(CurrentSceneMark(book.location) == .unavailable)
            book.structureUndo.undo()
            book.structureUndo.undo()
            #expect(book.book == before)
        }
    }

    /// An Errors-tab Fix can change a scene's id between a move and its undo; the undo still
    /// finds the scene.
    @Test func undoFindsAMovedSceneWhoseIDAFixChanged() async throws {
        let text = Self.text.replacingOccurrences(
            of: "- [line] kept since an earlier session\n",
            with: "- [line] kept since an earlier session\n- [metadata] id: renamed\n")
        try await withBook(text) { _, book, _ in
            let renamed = SceneID(rawValue: "renamed")
            #expect(book.change(.move(Self.letter, to: .end)))
            let ref = try #require(
                book.book.errorGroups.first { $0.owner == .scene(Self.letter) }?.refs.last)
            #expect(book.repairError(ref, as: "id: renamed") == .repaired)
            try #require(book.book.scenes.last?.id == renamed, "precondition: the Fix changed the id")

            book.structureUndo.undo()
            #expect(book.book.scenes.map(\.id) == [Self.ferry, renamed, Self.market])
            book.structureUndo.redo()
            #expect(book.book.scenes.map(\.id) == [Self.ferry, Self.market, renamed])
        }
    }

    @Test func aReadOnlyBookRefusesEveryChange() async throws {
        try await withTemporaryFolder { folder in
            let damaged = Self.text.replacingOccurrences(of: "id: ferry", with: "id: ferry boat")
            let url = try package(holding: Data(damaged.utf8), in: folder)
            let store = makeStore(
                in: folder, prompts: ScriptedPrompts([ReadOnlyChoice.keepReadOnly]),
                parseDefaults: fixedDefaults)
            _ = await store.open(url)
            let book = try #require(store.current)
            try #require(!book.isEditable, "precondition: a repaired book opens read-only")
            let before = book.book
            #expect(!book.change(.move(Self.market, to: .before(Self.letter))))
            #expect(!book.change(.cut(Self.letter)))
            #expect(!book.change(.restore(Self.brother, to: .end)))
            #expect(book.book == before && !book.structureUndo.canUndo)
            #expect(await store.closeBook() == .left)
        }
    }
}
