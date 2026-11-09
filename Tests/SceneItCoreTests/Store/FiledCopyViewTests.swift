import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// A filed copy open read-only over its book (PLAN §7.5): nothing can write to it, Close returns
/// to the book at its scene, and its two banner actions.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FiledCopyViewTests {
    static let record = FileACopyTests.record

    /// A book with two scenes, the second open, filed once; then the first scene's text changed, so
    /// the book and its copy differ.
    private func withFiledBook(
        prompts: ScriptedPrompts = ScriptedPrompts(),
        _ body: (TestStore, OpenBook<ManualClock>, URL, (ferry: SceneID, letter: SceneID)) async throws ->
            Void
    ) async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder, prompts: prompts)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let ferry = try #require(book.write("The ferry left at dawn."))
            let letter = try #require(book.write("He read it twice."))
            book.setTitle(of: ferry, to: "The ferry")
            book.addTag("draft", to: ferry)
            guard case .filed(let outcome) = await store.fileACopy(of: book, as: Self.record),
                outcome.isComplete
            else {
                Issue.record("precondition: a copy is filed, locked and indexed")
                return
            }
            book.replaceBody(of: ferry, with: [[Run("Rewritten since.")]])
            book.select(letter)
            try await body(store, book, url, (ferry, letter))
        }
    }

    private func open(_ store: TestStore, _ book: OpenBook<ManualClock>) async throws -> OpenBook<ManualClock>
    {
        try #require(await store.openFiledCopy(.first, of: book) == .opened)
        return try #require(store.shown, "precondition: the copy is shown")
    }

    @Test func theCopyShowsOverTheBookAtTheSceneItHadOpen() async throws {
        try await withFiledBook { store, book, url, scenes in
            let copy = try await open(store, book)
            #expect(copy !== book)
            #expect(store.current === book, "the book stays open, saving as before")
            #expect(store.openBook == nil, "File a Copy and Make Editable don't apply")
            #expect(copy.openScene == scenes.letter)
            #expect(
                copy.book.scene(scenes.ferry)?.body == [[Run("The ferry left at dawn.")]], "the copy's text")
            #expect(copy.status == .readOnly(.filedCopy))
            #expect(
                copy.document
                    == .filedCopy(
                        FiledCopyContext(
                            book: PackageLayout(root: url), copy: try #require(book.archive.copies.first))))
            #expect(
                FiledCopyWording.bannerDetail(try #require(copy.document.filedCopy))
                    == "\u{00B7} \(ArchiveWording.day(Self.record.filed)) \u{00B7} draft 4")

            store.closeFiledCopy()
            #expect(store.shown === book)
            #expect(book.openScene == scenes.letter, "back at the scene that was open")
            #expect(book.book.scene(scenes.ferry)?.body == [[Run("Rewritten since.")]])
        }
    }

    /// Trust: every way of changing a book is refused on the copy, and the copy's file, the index
    /// and the book's own file are exactly as they were once the copy is closed.
    @Test func nothingCanWriteToAFiledCopy() async throws {
        try await withFiledBook { store, book, url, scenes in
            let layout = PackageLayout(root: url)
            store.saveNow()
            await eventually { book.status == .saved }
            let archive = try DirectorySnapshot(layout.archive)
            let filed = try FileFingerprint(layout.filedCopy(.first))
            try #require(filed.immutable, "precondition: the copy is locked")
            let copy = try await open(store, book)
            let before = copy.book

            for kind in [EditKind.manuscript, .annotations, .errors, .archive] {
                #expect(!copy.accepts(kind), "\(kind)")
            }
            #expect(!copy.isEditable && !copy.canBeMadeEditable)
            copy.setTitle(of: scenes.ferry, to: "Changed")
            copy.replaceBody(of: scenes.ferry, with: [[Run("Changed")]])
            copy.replaceNotes(of: scenes.ferry, with: [[Run("Changed")]])
            #expect(copy.addScene(after: nil) == nil)
            #expect(copy.addScene(copying: try #require(copy.book.scene(scenes.ferry))) == nil)
            #expect(!copy.change(.cut(scenes.ferry)))
            #expect(!copy.addTag("new", to: scenes.ferry))
            #expect(!copy.removeTag("draft", from: scenes.ferry))
            #expect(copy.newComment(in: scenes.ferry, colored: .red) == nil)
            #expect(await store.editRecord(of: copy, .first, .addTag("x")) == .failed(.unavailable))
            #expect(await store.makeEditable() == .notRepaired)
            #expect(copy.book == before, "the copy in memory is unchanged")
            await #expect(throws: SaveError.self) { try await copy.save(SaveRequest(.typingPaused)) }

            store.closeFiledCopy()
            #expect(await store.closeBook() == .left)
            #expect(try FileFingerprint(layout.filedCopy(.first)) == filed, "bytes, inode, time and lock")
            #expect(try DirectorySnapshot(layout.archive) == archive, "nothing in Archive/ changed")
        }
    }

    @Test func restoringASceneAddsACopyOfItAtTheEndAsOneUndoStep() async throws {
        try await withFiledBook { store, book, url, scenes in
            let copy = try await open(store, book)
            copy.select(scenes.ferry)
            let restored = try #require(store.restoreScene(from: copy))
            #expect(store.shown === book, "the book shows again")
            #expect(book.openScene == restored, "with the restored scene open")
            #expect(book.book.scenes.map(\.id) == [scenes.ferry, scenes.letter, restored])
            let scene = try #require(book.book.scene(restored))
            #expect(scene.title == "The ferry" && scene.tags == ["draft"])
            #expect(scene.body == [[Run("The ferry left at dawn.")]], "the copy's text")
            #expect(
                book.book.scene(scenes.ferry)?.body == [[Run("Rewritten since.")]], "the book's own is kept")
            #expect(book.structureUndo.undoActionName == FiledCopyWording.restoreUndoName)

            book.structureUndo.undo()
            #expect(book.book.scenes.map(\.id) == [scenes.ferry, scenes.letter])
            #expect(book.openScene == scenes.letter, "the scene that was open opens again")
            book.structureUndo.redo()
            #expect(book.book.scenes.map(\.id) == [scenes.ferry, scenes.letter, restored])
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scenes.map(\.id) == [scenes.ferry, scenes.letter, restored])
        }
    }

    @Test func aNewBookFromTheCopyIsMadeButNotOpened() async throws {
        let prompts = ScriptedPrompts()
        try await withFiledBook(prompts: prompts) { store, book, url, scenes in
            let copy = try await open(store, book)
            let filed = try FileFingerprint(PackageLayout(root: url).filedCopy(.first))
            let made = url.deletingLastPathComponent().appending(
                path: "Then.sceneit", directoryHint: .isDirectory)

            #expect(await store.newBook(from: copy, at: made) == .created)

            #expect(try bookOnDisk(made).scenes.map(\.body) == copy.book.scenes.map(\.body))
            #expect(store.shown === copy, "still showing the copy")
            #expect(store.recentBooks.map(\.canonicalPath) == [url.canonicalPath, made.canonicalPath])
            #expect(prompts.notices == [FiledCopyWording.newBookMade(made)])
            #expect(try FileFingerprint(PackageLayout(root: url).filedCopy(.first)) == filed)
            #expect(
                await store.newBook(from: copy, at: made) == .failed(.alreadyExists(made)), "never replaced")
            _ = scenes
        }
    }

    @Test func closingTheBookWhileACopyShowsSavesTheBook() async throws {
        try await withFiledBook { store, book, url, scenes in
            _ = try await open(store, book)
            book.replaceBody(of: scenes.letter, with: [[Run("Typed before the copy opened.")]])
            #expect(await store.closeBook() == .left)
            #expect(store.isChoosing)
            #expect(
                try bookOnDisk(url).scene(scenes.letter)?.body == [[Run("Typed before the copy opened.")]])
        }
    }

    @Test func aCopyTheCabinetDoesntListDoesntOpen() async throws {
        try await withFiledBook { store, book, _, _ in
            #expect(await store.openFiledCopy(try #require(FiledCopyNumber(9)), of: book) == .unavailable)
            _ = try await open(store, book)
            #expect(await store.openFiledCopy(.first, of: book) == .unavailable, "one at a time")
        }
    }
}

extension OpenDocument {
    var filedCopy: FiledCopyContext? {
        if case .filedCopy(let context) = self { context } else { nil }
    }
}
