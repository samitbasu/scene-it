import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

private let noted = CommentID(rawValue: "01JC4K0000000000000000NOTE")
private let loose = CommentID(rawValue: "01JC4K0000000000000000LOSE")
private let other = CommentID(rawValue: "01JC4K0000000000000000OTHR")

/// Made with an expression: in a type position, `Comment` is ambiguous with the testing library's.
private let comment = { @Sendable (id: CommentID, text: String, color: PaletteColor) in
    Comment(
        id: id, color: color, text: text, created: Timestamp(secondsSince1970: 1_700_000_000, offset: .zero))
}

private let body: [Paragraph] = [
    [Run("The "), Run("letter", comments: [noted]), Run(" waited.")], [Run("Dawn.")],
]

/// The comment list's own operations (PLAN §8.1): text, color and dismiss, each one change on
/// the page's undo (§8.6), refused when the book is read-only.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CommentEditTests {
    /// A scene with an anchored comment, then a detached one, then another anchored one, so a
    /// dismiss from the middle shows the order kept.
    private func withComments(_ test: (OpenBook<ManualClock>, SceneID) async throws -> Void) async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            var commented = body
            commented[1] = [Run("Dawn.", comments: [other])]
            book.replaceBody(of: scene, with: commented)
            let comments = [
                comment(noted, "Too early?", .purple), comment(loose, "Cut?", .pink),
                comment(other, "Why?", .purple),
            ]
            #expect(book.apply(BodyChange(lines: 0..<0, paragraphs: []), to: scene, adding: comments) == [])
            try #require(book.book.scene(scene)?.comments.map(\.id) == [noted, loose, other])
            try #require(book.book.scene(scene)?.isDetached(loose) == true, "precondition: one is detached")
            book.pageUndo(for: scene).groupsByEvent = false
            try await test(book, scene)
        }
    }

    private func step(_ book: OpenBook<ManualClock>, _ scene: SceneID, _ change: () -> Void) {
        let undo = book.pageUndo(for: scene)
        undo.beginUndoGrouping()
        change()
        undo.endUndoGrouping()
    }

    @Test func aNewCommentIsEmptyInTheColorGivenWithAnIdOfItsOwnAndNotYetInTheScene() async throws {
        try await withComments { book, scene in
            let before = book.book
            let new = try #require(book.newComment(in: scene, colored: .black))
            #expect(new.text == "")
            #expect(new.color == .black, "a comment can be black (book format §4.4)")
            #expect(![noted, loose, other].contains(new.id))
            #expect(book.newComment(in: scene, colored: .red)?.id != new.id)
            #expect(book.book == before)
            #expect(book.newComment(in: SceneID(rawValue: "nowhere"), colored: .red) == nil)
        }
    }

    /// A new comment reaches the scene with the page's edit that covers its text, and undoing
    /// that edit and the paste-style removal leaves the scene as it was.
    @Test func aNewCommentArrivesWithTheTextItCoversAndSaves() async throws {
        try await withComments { book, scene in
            let new = try #require(book.newComment(in: scene, colored: .blue))
            let change = BodyChange(lines: 1..<2, paragraphs: [[Run("Dawn.", comments: [other, new.id])]])
            #expect(book.apply(change, to: scene, adding: [new]) == change.paragraphs)
            #expect(book.book.scene(scene)?.comments.last == new)
            let saved = try BookFormat.verifiedSerialization(of: book.book)
            var ids = IDGenerator.system
            let reread = BookFormat.parse(saved, opened: BookFormat.rereadTime, ids: &ids).book.scene(scene)
            #expect(reread?.comments.last?.color == .blue)
            #expect(reread?.body[1] == [Run("Dawn.", comments: [other, new.id])])
        }
    }

    @Test func editingTheTextIsOneUndoableChangeThroughTheCharacterPolicy() async throws {
        try await withComments { book, scene in
            let undo = book.pageUndo(for: scene)
            step(book, scene) {
                #expect(book.setText("Too \u{201C}early\u{201D}?", ofComment: noted, in: scene))
            }
            #expect(book.book.scene(scene)?.comments.first?.text == "Too \"early\"?")
            #expect(book.hasUnsavedEdits)
            #expect(undo.undoActionName == CommentWording.editUndoName)
            undo.undo()
            #expect(book.book.scene(scene)?.comments.first?.text == "Too early?")
            #expect(undo.redoActionName == CommentWording.editUndoName)
            undo.redo()
            #expect(book.book.scene(scene)?.comments.first?.text == "Too \"early\"?")
            #expect(book.notesUndo(for: scene).canUndo == false, "comments never reach the notes' history")
        }
    }

    /// A card's typing (#25): each draft reaches the model, to be saved, with no undo step; the
    /// edit then registers one step from the text it began with.
    @Test func draftsKeepTheTypingAndTheEditIsOneStepFromTheOriginal() async throws {
        try await withComments { book, scene in
            let undo = book.pageUndo(for: scene)
            for text in ["Too early?!", "Too early?! Or", "Too early?! Or late?"] {
                #expect(book.draftText(text, ofComment: noted, in: scene))
            }
            #expect(book.book.scene(scene)?.comments.first?.text == "Too early?! Or late?")
            #expect(book.hasUnsavedEdits)
            #expect(!undo.canUndo, "drafts register nothing")
            step(book, scene) {
                #expect(
                    book.setText("Too early?! Or late?", ofComment: noted, in: scene, since: "Too early?"))
            }
            #expect(undo.undoActionName == CommentWording.editUndoName)
            undo.undo()
            #expect(book.book.scene(scene)?.comments.first?.text == "Too early?")
            #expect(!undo.canUndo, "one step for the whole edit")
            undo.redo()
            #expect(book.book.scene(scene)?.comments.first?.text == "Too early?! Or late?")
        }
    }

    /// The review's case (#25): type, recolor, type, commit, then undo twice. Each inverse
    /// restores its own field alone, so the original text and color both come back, and the
    /// half-typed draft never does.
    @Test func undoingAnEditAndARecolorDuringItRestoresTheOriginal() async throws {
        try await withComments { book, scene in
            let undo = book.pageUndo(for: scene)
            #expect(book.draftText("Too early? Or", ofComment: noted, in: scene))
            step(book, scene) { #expect(book.recolor(noted, in: scene, to: .green)) }
            #expect(book.draftText("Too early? Or late?", ofComment: noted, in: scene))
            step(book, scene) {
                #expect(book.setText("Too early? Or late?", ofComment: noted, in: scene, since: "Too early?"))
            }
            undo.undo()
            #expect(book.book.scene(scene)?.comment(noted)?.text == "Too early?")
            #expect(
                book.book.scene(scene)?.comment(noted)?.color == .green, "the edit's undo leaves the color")
            undo.undo()
            #expect(book.book.scene(scene)?.comment(noted) == comment(noted, "Too early?", .purple))
            undo.redo()
            undo.redo()
            #expect(book.book.scene(scene)?.comment(noted) == comment(noted, "Too early? Or late?", .green))
        }
    }

    @Test func anEditThatEndsWhereItBeganRegistersNothing() async throws {
        try await withComments { book, scene in
            #expect(book.draftText("Too", ofComment: noted, in: scene))
            #expect(book.setText("Too early?", ofComment: noted, in: scene, since: "Too early?"))
            #expect(book.book.scene(scene)?.comments.first?.text == "Too early?")
            #expect(!book.pageUndo(for: scene).canUndo)
        }
    }

    @Test func anUnchangedTextOrColorRegistersNothing() async throws {
        try await withComments { book, scene in
            #expect(book.setText("Too early?", ofComment: noted, in: scene))
            #expect(book.recolor(noted, in: scene, to: .purple))
            #expect(!book.pageUndo(for: scene).canUndo)
        }
    }

    @Test func recoloringIsOneUndoableChange() async throws {
        try await withComments { book, scene in
            let undo = book.pageUndo(for: scene)
            step(book, scene) { #expect(book.recolor(other, in: scene, to: .black)) }
            #expect(book.book.scene(scene)?.comments.last?.color == .black)
            #expect(undo.undoActionName == CommentWording.recolorUndoName)
            undo.undo()
            #expect(book.book.scene(scene)?.comments.last?.color == .purple)
            undo.redo()
            #expect(book.book.scene(scene)?.comments.last?.color == .black)
            _ = try BookFormat.verifiedSerialization(of: book.book)
        }
    }

    @Test func anUnknownCommentIsRefused() async throws {
        try await withComments { book, scene in
            let before = book.book
            let stray = CommentID(rawValue: "01JC4K000000000000000STRAY")
            #expect(!book.setText("x", ofComment: stray, in: scene))
            #expect(!book.recolor(stray, in: scene, to: .red))
            #expect(!book.dismiss(stray, in: scene))
            #expect(!book.setText("x", ofComment: noted, in: SceneID(rawValue: "nowhere")))
            #expect(book.book == before)
        }
    }

    /// PLAN §8.1: a dismissed comment is removed, not archived; undoing the dismiss puts it back
    /// in its place in the list.
    @Test func dismissingADetachedCommentRemovesItAndUndoPutsItBackInPlace() async throws {
        try await withComments { book, scene in
            let undo = book.pageUndo(for: scene)
            step(book, scene) { #expect(book.dismiss(loose, in: scene)) }
            #expect(book.book.scene(scene)?.comments.map(\.id) == [noted, other])
            #expect(undo.undoActionName == CommentWording.dismissUndoName)
            undo.undo()
            #expect(book.book.scene(scene)?.comments.map(\.id) == [noted, loose, other])
            #expect(book.book.scene(scene)?.comments[1] == comment(loose, "Cut?", .pink))
            undo.redo()
            #expect(book.book.scene(scene)?.comments.map(\.id) == [noted, other])
            _ = try BookFormat.verifiedSerialization(of: book.book)
        }
    }

    @Test func aCommentTextStillCarriesIsNotDismissedHere() async throws {
        try await withComments { book, scene in
            let before = book.book
            #expect(!book.dismiss(noted, in: scene), "the page takes it off its text first")
            #expect(book.book == before)
            #expect(!book.pageUndo(for: scene).canUndo)
        }
    }

    @Test func aReadOnlyBookRefusesEveryCommentOperation() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Held.sceneit")
            let holder = try BookPackage.create(at: url, title: "Held")
            var ids = IDGenerator.system
            let held = BookScene(
                id: ids.sceneID(), modified: Timestamp(secondsSince1970: 1_700_000_000, offset: .zero),
                title: "One", body: body,
                comments: [comment(noted, "Too early?", .purple), comment(loose, "Cut?", .purple)])
            _ = try holder.package.save(Book(title: "Held", scenes: [held]))
            let store = makeStore(in: folder)
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            let book = try #require(store.current)
            let before = book.book
            #expect(book.newComment(in: held.id, colored: .red) == nil)
            #expect(!book.setText("No", ofComment: noted, in: held.id))
            #expect(!book.draftText("No", ofComment: noted, in: held.id))
            #expect(!book.recolor(noted, in: held.id, to: .red))
            #expect(!book.dismiss(loose, in: held.id))
            #expect(!book.removeComments([loose], from: held.id))
            #expect(book.book == before)
            #expect(!book.pageUndo(for: held.id).canUndo)
            #expect(await store.closeBook() == .left)
            withExtendedLifetime(holder) {}
        }
    }
}
