import Foundation
import Testing

@testable import SceneItCore

private let noted = CommentID(rawValue: "01JC4K0000000000000000NOTE")
private let stray = CommentID(rawValue: "01JC4K000000000000000STRAY")

private let tooEarly = Comment(
    id: noted, color: .purple, text: "Too early?",
    created: Timestamp(secondsSince1970: 1_700_000_000, offset: .zero))

/// The notes take the same ranged edits as the body (PLAN §8.2), with their own history (§8.6),
/// and never count as words (§4.5).
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct NotesEditTests {
    /// A book with one scene whose body and notes each hold a line, and a comment on its body.
    private func withScene(_ body: (OpenBook<ManualClock>, SceneID) async throws -> Void) async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            book.replaceBody(of: scene, with: [[Run("The "), Run("letter", comments: [noted])]])
            book.replaceNotes(of: scene, with: [[Run("Check the tides.")]])
            #expect(book.apply(BodyChange(lines: 0..<0, paragraphs: []), to: scene, adding: [tooEarly]) == [])
            try await body(book, scene)
        }
    }

    @Test func aChangeToTheNotesReplacesOnlyItsLinesThereAndCountsNoWords() async throws {
        try await withScene { book, scene in
            let before = try #require(book.book.scene(scene))
            let counts = book.wordCounts
            let change = BodyChange(
                lines: 0..<1, paragraphs: [[Run("Check the tides,", styles: [.bold])], [Run("twice.")]])
            #expect(book.apply(change, to: scene, in: .notes) == change.paragraphs)
            let edited = try #require(book.book.scene(scene))
            #expect(edited.notes == change.paragraphs)
            #expect(edited.body == before.body, "the body is untouched")
            #expect(book.wordCounts == counts, "notes aren't words of the manuscript")
            #expect(book.wordCounts[scene] == WordCount(edited.body))
            #expect(book.hasUnsavedEdits)
            #expect(
                book.apply(BodyChange(lines: 2..<3, paragraphs: [[Run("x")]]), to: scene, in: .notes) == nil)
            _ = try BookFormat.verifiedSerialization(of: book.book)
        }
    }

    /// Book format §4.2: a comment may cover the notes' text as well as the body's.
    @Test func aCommentCanCoverTheNotesAndAnUnknownIdIsDropped() async throws {
        try await withScene { book, scene in
            let change = BodyChange(
                lines: 0..<1, paragraphs: [[Run("Check "), Run("the tides.", comments: [noted, stray])]])
            #expect(
                book.apply(change, to: scene, in: .notes)
                    == [[Run("Check "), Run("the tides.", comments: [noted])]])
            book.replaceBody(of: scene, with: [[Run("No comment here.")]])
            let edited = try #require(book.book.scene(scene))
            #expect(!edited.isDetached(noted), "the notes carry the comment")
            let saved = try BookFormat.verifiedSerialization(of: book.book)
            #expect(String(decoding: saved, as: UTF8.self).contains("notes c6-16"))
        }
    }

    @Test func eachScenesNotesHaveTheirOwnUndoApartFromItsPage() async throws {
        try await withScene { book, scene in
            let other = try #require(book.addScene(after: scene))
            #expect(book.notesUndo(for: scene) === book.notesUndo(for: scene))
            #expect(book.notesUndo(for: scene) !== book.notesUndo(for: other))
            #expect(book.notesUndo(for: scene) !== book.pageUndo(for: scene))
            #expect(book.notesUndo(for: scene) !== book.titleUndo(for: scene))
            #expect(book.undo(for: scene, .notes) === book.notesUndo(for: scene))
            #expect(book.undo(for: scene, .body) === book.pageUndo(for: scene))
        }
    }

    @Test func replacingTheNotesFromElsewhereClearsOnlyTheNotesHistory() async throws {
        try await withScene { book, scene in
            let notes = book.notesUndo(for: scene)
            let page = book.pageUndo(for: scene)
            for undo in [notes, page] {
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                undo.registerUndo(withTarget: book) { _ in }
                undo.endUndoGrouping()
            }
            book.apply(BodyChange(lines: 0..<1, paragraphs: [[Run("Typed.")]]), to: scene, in: .notes)
            #expect(notes.canUndo, "the notes' own edits keep their history")
            book.replaceNotes(of: scene, with: [[Run("Replaced.")]])
            #expect(!notes.canUndo)
            #expect(page.canUndo, "the page's history is its own")
        }
    }

    /// A paste into the notes that brought comments is undone on the notes' history.
    @Test func removingCommentsPastedIntoTheNotesIsUndoneOnTheNotes() async throws {
        try await withScene { book, scene in
            book.replaceBody(of: scene, with: [])
            let undo = book.notesUndo(for: scene)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            book.removeComments([noted], from: scene, pastedInto: .notes)
            undo.endUndoGrouping()
            #expect(book.book.scene(scene)?.comments.isEmpty == true)
            #expect(!book.pageUndo(for: scene).canUndo, "nothing reaches the page's history")
            undo.undo()
            #expect(book.book.scene(scene)?.comments.map(\.id) == [noted])
            undo.redo()
            #expect(book.book.scene(scene)?.comments.isEmpty == true)
        }
    }
}
