import Foundation
import Testing

@testable import SceneItCore

private let noted = CommentID(rawValue: "01JC4K0000000000000000NOTE")
private let stray = CommentID(rawValue: "01JC4K000000000000000STRAY")

private let tooEarly = Comment(
    id: noted, color: .purple, text: "Too early?",
    created: Timestamp(secondsSince1970: 1_700_000_000, offset: .zero))

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PageEditTests {
    /// A book with one scene holding a commented, colored span.
    private func withCommentedScene(_ body: (OpenBook<ManualClock>, SceneID) async throws -> Void)
        async throws
    {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            book.replaceBody(
                of: scene,
                with: [
                    [Run("The "), Run("letter", color: .red, comments: [noted]), Run(" waited.")],
                    [Run("Dawn.")],
                ])
            #expect(book.apply(BodyChange(lines: 0..<0, paragraphs: []), to: scene, adding: [tooEarly]) == [])
            #expect(book.book.scene(scene)?.comments.map(\.id) == [noted])
            try await body(book, scene)
        }
    }

    @Test func aChangeReplacesOnlyItsLinesAndKeepsTheWordCountExact() async throws {
        try await withCommentedScene { book, scene in
            let change = BodyChange(lines: 1..<2, paragraphs: [[Run("Dawn came")], [Run("and went.")]])
            #expect(book.apply(change, to: scene) == change.paragraphs)
            let edited = try #require(book.book.scene(scene))
            #expect(edited.body.count == 3)
            #expect(edited.body[0].runs[1].comments == [noted])
            #expect(book.wordCounts[scene] == edited.wordCount)
            #expect(book.hasUnsavedEdits)
        }
    }

    @Test func anIdTheSceneHasNoCommentForIsNeverWritten() async throws {
        try await withCommentedScene { book, scene in
            let change = BodyChange(
                lines: 1..<2, paragraphs: [[Run("Dawn", comments: [stray, noted])]])
            #expect(book.apply(change, to: scene) == [[Run("Dawn", comments: [noted])]])
            let edited = try #require(book.book.scene(scene))
            #expect(Paragraph.commentIDs(in: edited.body) == [noted])
            _ = try BookFormat.verifiedSerialization(of: book.book)
        }
    }

    @Test func aChangeOutsideTheBodyIsRefused() async throws {
        try await withCommentedScene { book, scene in
            let before = book.book
            #expect(book.apply(BodyChange(lines: 2..<3, paragraphs: [[Run("x")]]), to: scene) == nil)
            #expect(book.book == before)
        }
    }

    @Test func aClipRoundTripsThroughThePasteboardData() async throws {
        try await withCommentedScene { book, scene in
            let source = try #require(book.book.scene(scene))
            let lines: [Paragraph] = [
                [Run(" letter", color: .red, comments: [noted]), Run(" ")], [], [Run("*Dawn* \\ ")],
            ]
            let clip = PageClip(lines, from: source)
            #expect(clip.comments.map(\.id) == [noted])
            let data = try #require(clip.data)
            #expect(PageClip(data: data) == clip)
            #expect(PageClip(data: Data("not a clip".utf8)) == nil)
        }
    }

    @Test func pastingIntoTheSameSceneKeepsTheIds() async throws {
        try await withCommentedScene { book, scene in
            let clip = PageClip(
                [[Run("letter", color: .red, comments: [noted])]], from: try #require(book.book.scene(scene)))
            let pasted = try #require(book.resolve(clip, into: scene))
            #expect(pasted.lines == clip.lines)
            #expect(pasted.comments.isEmpty)
        }
    }

    @Test func pastingIntoAnotherSceneCopiesTheCommentsWithFreshIds() async throws {
        try await withCommentedScene { book, scene in
            let clip = PageClip(
                [[Run("letter", color: .red, comments: [noted])]], from: try #require(book.book.scene(scene)))
            let other = try #require(book.addScene(after: scene))
            let pasted = try #require(book.resolve(clip, into: other))
            let copy = try #require(pasted.comments.first)
            #expect(pasted.comments.count == 1)
            #expect(copy.id != noted)
            #expect(copy.text == "Too early?")
            #expect(pasted.lines == [[Run("letter", color: .red, comments: [copy.id])]])

            #expect(
                book.apply(
                    BodyChange(lines: 0..<1, paragraphs: pasted.lines), to: other, adding: pasted.comments)
                    != nil)
            #expect(book.book.scene(other)?.comments == [copy])
            #expect(book.book.scene(scene)?.comments.map(\.id) == [noted], "the source is untouched")
            _ = try BookFormat.verifiedSerialization(of: book.book)
        }
    }

    @Test func aDismissedCommentPastesAsACopy() async throws {
        try await withCommentedScene { book, scene in
            let clip = PageClip(
                [[Run("letter", comments: [noted])]], from: try #require(book.book.scene(scene)))
            book.replaceBody(of: scene, with: [[Run("Gone.")]])
            book.removeComments([noted], from: scene)
            #expect(book.book.scene(scene)?.comments.isEmpty == true)
            let pasted = try #require(book.resolve(clip, into: scene))
            #expect(pasted.comments.count == 1)
            #expect(pasted.comments.first?.id != noted)
        }
    }

    @Test func removingPastedCommentsIsUndoneOnThePageAndSparesCommentsInUse() async throws {
        try await withCommentedScene { book, scene in
            book.removeComments([noted], from: scene)
            #expect(book.book.scene(scene)?.comments.map(\.id) == [noted], "the text still carries it")

            book.replaceBody(of: scene, with: [])
            let undo = book.pageUndo(for: scene)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            book.removeComments([noted], from: scene)
            undo.endUndoGrouping()
            #expect(book.book.scene(scene)?.comments.isEmpty == true)
            undo.undo()
            #expect(book.book.scene(scene)?.comments.map(\.id) == [noted])
            undo.redo()
            #expect(book.book.scene(scene)?.comments.isEmpty == true)
        }
    }

    @Test func eachScenesPageHasItsOwnUndoClearedWhenItsBodyIsReplacedFromElsewhere() async throws {
        try await withCommentedScene { book, scene in
            let other = try #require(book.addScene(after: scene))
            #expect(book.pageUndo(for: scene) === book.pageUndo(for: scene))
            #expect(book.pageUndo(for: scene) !== book.pageUndo(for: other))
            let undo = book.pageUndo(for: scene)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: book) { _ in }
            undo.endUndoGrouping()
            #expect(undo.canUndo)
            book.apply(BodyChange(lines: 1..<2, paragraphs: [[Run("Typed.")]]), to: scene)
            #expect(undo.canUndo, "the page's own edits keep its history")
            book.replaceBody(of: scene, with: [[Run("Replaced.")]])
            #expect(!undo.canUndo)
        }
    }
}
