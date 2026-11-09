import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// Review Book… through the store (ADR 0042): a review opens as a book whose text nothing can
/// change, takes comments and notes, saves them to its review file and resumes from it; a
/// damaged review opens read-only until Make Editable; one book or review at a time.
@MainActor
struct ReviewStoreTests {
    /// The TIDE copy as `Tide.md` in `folder`.
    static func copy(in folder: URL) throws -> URL {
        let url = folder.appending(path: "Tide.md")
        try Data(ReviewFormatTests.tide.utf8).write(to: url)
        return url
    }

    static func reviewText(in folder: URL) throws -> String {
        try String(decoding: Data(contentsOf: folder.appending(path: "Tide.review.md")), as: UTF8.self)
    }

    static let dawn = SceneID(rawValue: "s1")

    /// Comments "ferry" in Dawn ("The ferry left at dawn.") through the page's own path: a new
    /// comment, added by the edit that puts its id on the text.
    @discardableResult
    static func commentFerry(in book: OpenBook<ManualClock>, saying text: String) -> CommentID? {
        guard let comment = book.newComment(in: dawn, colored: .red) else { return nil }
        let change = BodyChange(
            lines: 0..<1,
            paragraphs: [[Run("The "), Run("ferry", comments: [comment.id]), Run(" left at dawn.")]])
        guard book.apply(change, to: dawn, adding: [comment]) != nil else { return nil }
        book.setText(text, ofComment: comment.id, in: dawn)
        return comment.id
    }

    @Test func aReviewOpensAsABookWhoseTextNothingChanges() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            #expect(await store.openReview(try Self.copy(in: folder)) == .opened)
            let book = try #require(store.current)
            #expect(book.document.kind == .review)
            #expect(book.isEditable)
            #expect(book.accepts(.annotations) && book.accepts(.errors))
            #expect(!book.accepts(.manuscript))
            #expect(store.fileableBook == nil)

            let before = book.book
            book.setTitle(of: Self.dawn, to: "Morning")
            book.replaceBody(of: Self.dawn, with: [[Run("Rewritten.")]])
            #expect(
                book.apply(BodyChange(lines: 0..<1, paragraphs: [[Run("Typed over.")]]), to: Self.dawn) == nil
            )
            #expect(
                book.apply(
                    BodyChange(lines: 0..<1, paragraphs: [[Run("The ferry left at dawn.", styles: [.bold])]]),
                    to: Self.dawn) == nil, "formatting is a change to the text")
            #expect(book.addScene(after: nil) == nil)
            #expect(!book.addTag("draft", to: Self.dawn))
            #expect(book.book == before)
            #expect(!book.hasUnsavedEdits)
        }
    }

    @Test func commentsAndNotesAreSavedToTheReviewFileAndTheCopyIsNeverWritten() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let copy = try Self.copy(in: folder)
            let copyBytes = try Data(contentsOf: copy)
            await store.openReview(copy)
            let book = try #require(store.current)
            let modified = try #require(book.book.scene(Self.dawn)?.modified)
            try #require(Self.commentFerry(in: book, saying: "Which ferry?") != nil)
            #expect(
                book.apply(
                    BodyChange(lines: 0..<1, paragraphs: [[Run("Lovely.")]]), to: Self.dawn, in: .notes)
                    != nil)
            #expect(
                book.book.scene(Self.dawn)?.modified == modified, "a review's scenes keep the copy's times")
            #expect(book.hasUnsavedEdits)

            #expect(await store.closeBook() == .left)
            let text = try Self.reviewText(in: folder)
            #expect(text.contains(#"| c4-9 | "ferry" | Which ferry?"#))
            #expect(text.contains("### Notes\nLovely."))
            #expect(try Data(contentsOf: copy) == copyBytes)

            #expect(await store.openReview(copy) == .opened)
            let again = try #require(store.current?.book.scene(Self.dawn))
            #expect(again.comments.map(\.text) == ["Which ferry?"])
            #expect(again.notes == [[Run("Lovely.")]])
            #expect(!again.isDetached(again.comments[0].id))
            #expect(try Data(contentsOf: copy) == copyBytes)
        }
    }

    @Test func oneBookOrReviewAtATime() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let copy = try Self.copy(in: folder)
            let novel = try await createBook("Novel", in: folder, store: store)
            #expect(await store.openReview(copy) == .refused)
            #expect(store.current?.document.url.canonicalPath == novel.canonicalPath)
            await store.closeBook()
            #expect(await store.openReview(copy) == .opened)
            #expect(await store.openReview(copy) == .alreadyOpen)
            #expect(await store.open(novel) == .refused)
            #expect(prompts.notices.count == 2)
        }
    }

    @Test func aFileThatIsntACopyIsRefusedWithANotice() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let notes = folder.appending(path: "notes.md")
            try Data("Just some notes.\n".utf8).write(to: notes)
            #expect(await store.openReview(notes) == .reviewFailed(.notAReviewCopy(notes)))
            #expect(store.isChoosing)
            #expect(prompts.notices.map(\.title) == ["“notes.md” isn't a review copy."])
        }
    }

    @Test func aDamagedReviewOpensReadOnlyUntilMakeEditableKeepsItsOriginal() async throws {
        try await withTemporaryFolder { folder in
            let prompts = ScriptedPrompts()
            let store = makeStore(in: folder, prompts: prompts)
            let copy = try Self.copy(in: folder)
            let damaged = ReviewFormatTests.fm + "\n\nStray line.\n\n## Dawn\nid: s1\n\n### Notes\nKept.\n"
            let reviewFile = folder.appending(path: "Tide.review.md")
            try Data(damaged.utf8).write(to: reviewFile)

            guard case .openedReadOnly(.repairedOnOpen) = await store.openReview(copy) else {
                Issue.record("expected the damaged review to open read-only")
                return
            }
            #expect(prompts.labels.last == [ReadOnlyWording.keepReadOnly, ReadOnlyWording.makeEditable])
            let book = try #require(store.current)
            #expect(!book.isEditable)
            #expect(store.canMakeEditable)
            #expect(book.newComment(in: Self.dawn, colored: .red) == nil)
            #expect(try Data(contentsOf: reviewFile) == Data(damaged.utf8))

            prompts.answer([ReadOnlyChoice.makeEditable])
            #expect(await store.confirmMakeEditable() == .editable)
            #expect(prompts.titles.last == "Make This Review Editable?")
            #expect(book.accepts(.annotations))
            let reviewID = ReviewID(rawValue: "01JDD8WQ4K7M2N9P3R5S6T8V0X")
            let side = ReviewsFolder(root: folder.appending(path: "Reviews")).folder(for: reviewID)
            let kept = try FileManager.default.contentsOfDirectory(atPath: side.path(percentEncoded: false))
                .filter { $0.hasPrefix("review.md.original-") }
            #expect(kept.count == 1)
            await store.closeBook()
            #expect(try Self.reviewText(in: folder).contains("### Unparsed\n- [line] Stray line."))
            #expect(try Data(contentsOf: side.appending(path: kept[0])) == Data(damaged.utf8))
        }
    }

    @Test func aReviewOnlyFixesCommentEntries() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder, prompts: ScriptedPrompts([ReadOnlyChoice.makeEditable]))
            let copy = try Self.copy(in: folder)
            try Data(
                (ReviewFormatTests.fm
                    + "\n\n## Dawn\nid: s1\nmodified: 2026-11-02T09:00:00-08:00\n\n### Comments\n"
                    + "- c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | \"fer\" | Which?\n").utf8
            ).write(to: folder.appending(path: "Tide.review.md"))
            #expect(await store.openReview(copy) == .opened)
            let book = try #require(store.current)
            let errors = try #require(book.book.scene(Self.dawn)?.errors)
            #expect(errors.map(\.tag) == [.metadata, .comments])
            let metadata = ErrorRef(owner: .scene(Self.dawn), index: 0, entry: errors[0])
            #expect(!book.canRepair(metadata))
            #expect(book.repairError(metadata, as: errors[0].payload) == .refused)
            let comment = ErrorRef(owner: .scene(Self.dawn), index: 1, entry: errors[1])
            #expect(book.canRepair(comment))
            #expect(
                book.repairError(
                    comment, as: #"- c1 | red | 2026-11-04T09:12:00-08:00 | c4-9 | "ferry" | Which?"#)
                    == .repaired)
            #expect(book.book.scene(Self.dawn)?.comments.map(\.text) == ["Which?"])
            #expect(book.deleteError(ErrorRef(owner: .scene(Self.dawn), index: 0, entry: errors[0])))
            await store.closeBook()
            let text = try Self.reviewText(in: folder)
            #expect(text.contains(#"| c4-9 | "ferry" | Which?"#))
            #expect(!text.contains("modified"))
        }
    }
}
