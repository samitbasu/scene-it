import Foundation
import Testing

@testable import SceneItCore

/// The Errors tab's operations through the open book (book format §5.4): each tells autosave
/// in the same turn, is undoable on `structureUndo`, and is refused while the book is read-only.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ErrorEntryEditTests {
    static let created = "2026-10-31T20:40:00-07:00"
    static let broken = "- c1 | purple | \(created) | c12-18 | \"lettre\" | Too early?"
    static let fixed = "- c1 | purple | \(created) | c12-18 | \"letter\" | Too early?"

    /// A book whose entries were kept by an earlier session, so it opens for editing.
    static let text = """
        ---
        title: Novel
        format: 2
        ---

        ### Unparsed
        - [line] Remember to back this up!

        ## The ferry
        id: ferry
        modified: \(created)

        He read the letter twice.

        ### Unparsed
        - [comments] \(broken)
        - [metadata] mood: grim

        """

    private func openBook(
        _ text: String = Self.text, in folder: URL, prompts: ScriptedPrompts = ScriptedPrompts()
    ) async throws -> (TestStore, OpenBook<ManualClock>, URL) {
        let url = try package(holding: Data(text.utf8), in: folder)
        let store = makeStore(in: folder, prompts: prompts, parseDefaults: fixedDefaults)
        _ = await store.open(url)
        return (store, try #require(store.current), url)
    }

    private func ref(_ tag: ErrorTag, in book: OpenBook<ManualClock>) throws -> ErrorRef {
        try #require(book.book.errorGroups.flatMap(\.refs).first { $0.entry.tag == tag })
    }

    @Test func deletingAnEntryIsSavedAndUndoable() async throws {
        try await withTemporaryFolder { folder in
            let (store, book, url) = try await openBook(in: folder)
            #expect(book.isEditable && book.status == .saved, "precondition: kept entries open for editing")
            let before = book.book
            let line = try ref(.line, in: book)

            #expect(book.deleteError(line))
            #expect(book.status == .unsaved, "autosave heard in the same turn")
            #expect(book.book.errors.isEmpty)
            #expect(book.book.scenes == before.scenes)
            #expect(!book.deleteError(line), "a row that's gone can't be deleted twice")

            book.structureUndo.undo()
            #expect(book.book == before)
            book.structureUndo.redo()
            #expect(book.book.errors.isEmpty)

            store.saveNow()
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url) == book.book)
            #expect(try bookOnDisk(url).errorCount == 2)
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func aRepairedCommentMovesIntoTheSceneAndIsSaved() async throws {
        try await withTemporaryFolder { folder in
            let (store, book, url) = try await openBook(in: folder)
            let before = book.book
            let comment = try ref(.comments, in: book)
            #expect(BookFormat.reason(for: comment, in: book.book) == .comment(.quoteMismatch))

            #expect(book.repairError(comment, as: Self.fixed) == .repaired)
            #expect(book.status == .unsaved)
            let scene = try #require(book.book.scenes.first)
            #expect(scene.comments.map(\.id.rawValue) == ["c1"])
            #expect(scene.errors == [ErrorEntry(.metadata, "mood: grim")])
            #expect(scene.modified == before.scenes[0].modified, "a repair isn't an edit of the text")

            store.saveNow()
            await eventually { book.status == .saved }
            let saved = try bookOnDisk(url)
            #expect(saved == book.book)
            #expect(
                saved.scenes[0].body[0].runs.contains(Run("letter", comments: [CommentID(rawValue: "c1")])))

            book.structureUndo.undo()
            #expect(book.book == before)
            #expect(book.status == .unsaved)
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func anEditThatStillDoesntReadIsKeptAndSaved() async throws {
        try await withTemporaryFolder { folder in
            let (store, book, url) = try await openBook(in: folder)
            let comment = try ref(.comments, in: book)
            let edited = Self.broken.replacingOccurrences(of: "purple", with: "mauve")
            #expect(book.repairError(comment, as: edited) == .kept(.comment(.paletteName)))
            #expect(book.status == .unsaved)
            #expect(book.book.scenes[0].errors.first == ErrorEntry(.comments, edited))
            store.saveNow()
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes[0].errors.first == ErrorEntry(.comments, edited))
            #expect(
                book.repairError(try ref(.line, in: book), as: "x") == .refused, "a [line] can't be repaired")
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func repairingTheOpenScenesIDKeepsItOpen() async throws {
        try await withTemporaryFolder { folder in
            let text = Self.text.replacingOccurrences(of: "id: ferry", with: "id: ferry boat")
            let prompts = ScriptedPrompts([ReadOnlyChoice.makeEditable])
            let (store, book, _) = try await openBook(text, in: folder, prompts: prompts)
            try #require(book.isEditable, "precondition: made editable from the alert")
            let id = try ref(.metadata, in: book)
            #expect(id.entry == ErrorEntry(.metadata, "id: ferry boat"))
            let old = try #require(book.openScene)
            #expect(book.repairError(id, as: "id: ferry") == .repaired)
            #expect(book.openScene == SceneID(rawValue: "ferry"))
            #expect(book.book.scenes[0].id == SceneID(rawValue: "ferry"))
            book.structureUndo.undo()
            #expect(book.openScene == old)
            #expect(book.book.scenes[0].id == old)
            #expect(await store.closeBook() == .left)
        }
    }

    /// The book in its file, read back, which must be the book itself.
    private func expectRoundTrip(_ book: Book, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: Never.self, sourceLocation: sourceLocation) {
            _ = try BookFormat.verifiedSerialization(of: book)
        }
    }

    @Test(arguments: [ErrorTag.comments, .marks])
    func undoingARepairKeepsWhatWasTypedSince(tag: ErrorTag) async throws {
        try await withTemporaryFolder { folder in
            let text = Self.text.replacingOccurrences(
                of: "- [comments] \(Self.broken)",
                with: tag == .comments
                    ? "- [comments] \(Self.broken)" : "- [marks] - color red | c12-19 | \"letter\"")
            let payload = tag == .comments ? Self.fixed : "- color red | c12-18 | \"letter\""
            let (store, book, _) = try await openBook(text, in: folder)
            let entry = try ref(tag, in: book)
            let scene = try #require(book.book.scenes.first?.id)
            let before = try #require(book.book.scenes.first)
            #expect(book.repairError(entry, as: payload) == .repaired)
            let repaired = try #require(book.book.scenes.first)
            #expect(
                repaired.body != before.body || repaired.comments != before.comments,
                "precondition: it took effect")

            book.replaceNotes(of: scene, with: [[Run("Typed after the repair.")]])
            book.setTitle(of: scene, to: "Retitled")
            book.structureUndo.undo()
            let undone = try #require(book.book.scenes.first)
            #expect(undone.notes == [[Run("Typed after the repair.")]], "later notes kept")
            #expect(undone.title == "Retitled", "later title kept")
            #expect(undone.body == before.body && undone.comments == before.comments, "the repair is gone")
            #expect(undone.errors == before.errors, "the entry is back where it was")
            expectRoundTrip(book.book)

            book.structureUndo.redo()
            let redone = try #require(book.book.scenes.first)
            #expect(redone.body == repaired.body && redone.comments == repaired.comments)
            #expect(redone.errors == repaired.errors)
            #expect(redone.notes == [[Run("Typed after the repair.")]] && redone.title == "Retitled")
            expectRoundTrip(book.book)
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func undoingADeleteKeepsWhatWasTypedSince() async throws {
        try await withTemporaryFolder { folder in
            let (store, book, _) = try await openBook(in: folder)
            let entry = try ref(.metadata, in: book)
            let scene = try #require(book.book.scenes.first?.id)
            let errors = try #require(book.book.scenes.first?.errors)
            #expect(book.deleteError(entry))
            book.replaceNotes(of: scene, with: [[Run("Typed after.")]])
            book.setTitle(of: scene, to: "Retitled")
            book.structureUndo.undo()
            #expect(book.book.scenes[0].errors == errors)
            #expect(
                book.book.scenes[0].notes == [[Run("Typed after.")]]
                    && book.book.scenes[0].title == "Retitled")
            expectRoundTrip(book.book)
            book.structureUndo.redo()
            #expect(book.book.scenes[0].errors == errors.filter { $0 != entry.entry })
            #expect(book.book.scenes[0].title == "Retitled")
            expectRoundTrip(book.book)
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func undoingAMetadataRepairPutsTheOldValueBack() async throws {
        try await withTemporaryFolder { folder in
            let (store, book, _) = try await openBook(in: folder)
            let mood = try ref(.metadata, in: book)
            #expect(book.repairError(mood, as: "tags: grim") == .repaired)
            #expect(book.book.scenes[0].tags == ["grim"])
            book.setTitle(of: book.book.scenes[0].id, to: "Retitled")
            book.structureUndo.undo()
            #expect(book.book.scenes[0].tags.isEmpty)
            #expect(book.book.scenes[0].title == "Retitled")
            #expect(book.book.scenes[0].errors.contains(ErrorEntry(.metadata, "mood: grim")))
            #expect(await store.closeBook() == .left)
        }
    }

    @Test func aReadOnlyBooksEntriesCantBeChangedUntilItsMadeEditable() async throws {
        try await withTemporaryFolder { folder in
            let (store, book, url) = try await openBook(Self.text + "\nNot an entry\n", in: folder)
            guard case .readOnly(.repairedOnOpen) = book.status else {
                Issue.record("precondition: a repaired book opens read-only, got \(book.status)")
                return
            }
            let before = book.book
            let comment = try ref(.comments, in: book)
            #expect(!book.deleteError(comment))
            #expect(book.repairError(comment, as: Self.fixed) == .refused)
            #expect(book.book == before)
            #expect(!book.structureUndo.canUndo)

            #expect(await store.makeEditable() == .editable)
            #expect(book.repairError(comment, as: Self.fixed) == .repaired)
            store.saveNow()
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes[0].comments.count == 1)
            #expect(await store.closeBook() == .left)
        }
    }
}
