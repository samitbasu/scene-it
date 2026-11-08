import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// The Tags tab's edits through the store (PLAN §8.3, #20): add, remove and toggle, each one
/// change on the scene's page undo (the owner's choice), saved to `book.md`, refused when the
/// book is read-only.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct TagEditTests {
    /// Two scenes: the one under test, tagged `Mara` and `clue`, and another tagged `set piece`.
    private func withTags(_ test: (OpenBook<ManualClock>, SceneID, URL) async throws -> Void) async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let url = try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let scene = try #require(book.addScene(after: nil))
            let other = try #require(book.addScene(after: scene))
            #expect(book.addTag("Mara", to: scene))
            #expect(book.addTag("clue", to: scene))
            #expect(book.addTag("set piece", to: other))
            book.pageUndo(for: scene).removeAllActions()
            book.pageUndo(for: scene).groupsByEvent = false
            try await test(book, scene, url)
        }
    }

    private func tags(_ book: OpenBook<ManualClock>, _ scene: SceneID) -> [String] {
        book.book.scene(scene)?.tags ?? []
    }

    private func step(_ book: OpenBook<ManualClock>, _ scene: SceneID, _ change: () -> Void) {
        let undo = book.pageUndo(for: scene)
        undo.beginUndoGrouping()
        change()
        undo.endUndoGrouping()
    }

    /// One scene whose tags are `tags` exactly as `book.md` holds them: case variants and
    /// duplicates included, which only a hand-edited file can give a scene.
    private func withFileTags(
        _ tags: [String], _ test: (OpenBook<ManualClock>, SceneID) async throws -> Void
    ) async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            let url = try await createBook("Novel", in: folder, store: store)
            #expect(await store.closeBook() == .left)
            var ids = IDGenerator.system
            let held = BookScene(
                id: ids.sceneID(), modified: Timestamp(secondsSince1970: 1_700_000_000, offset: .zero),
                title: "One", tags: tags)
            try BookFormat.serialize(Book(title: "Novel", scenes: [held])).write(
                to: url.appending(path: "book.md"), options: .atomic)
            #expect(await store.open(url) == .opened)
            let book = try #require(store.current)
            try #require(book.book.scene(held.id)?.tags == tags, "precondition: the file's tags as written")
            book.pageUndo(for: held.id).groupsByEvent = false
            try await test(book, held.id)
        }
    }

    /// The review's case (#20): removing a tag takes every case variant of it, and undo puts
    /// each back exactly, where it was; redo takes them all again.
    @Test func removingTakesEveryCaseVariantAndUndoPutsThemAllBack() async throws {
        try await withFileTags(["Mara", "clue", "mara", "MARA"]) { book, scene in
            let undo = book.pageUndo(for: scene)
            step(book, scene) { #expect(book.toggleTag("Mara", on: scene)) }
            #expect(tags(book, scene) == ["clue"], "the row is off after one click")
            #expect(undo.undoActionName == TagWording.removeUndoName)
            undo.undo()
            #expect(tags(book, scene) == ["Mara", "clue", "mara", "MARA"])
            undo.redo()
            #expect(tags(book, scene) == ["clue"])
            undo.undo()
            #expect(tags(book, scene) == ["Mara", "clue", "mara", "MARA"])
        }
    }

    @Test func removingExactDuplicatesTakesAllAndUndoRestoresThem() async throws {
        try await withFileTags(["x", "y", "x"]) { book, scene in
            let undo = book.pageUndo(for: scene)
            step(book, scene) { #expect(book.removeTag("x", from: scene)) }
            #expect(tags(book, scene) == ["y"])
            undo.undo()
            #expect(tags(book, scene) == ["x", "y", "x"])
            undo.redo()
            #expect(tags(book, scene) == ["y"])
        }
    }

    /// A row adds its tag exactly as the book spells it: a `#` the tag starts with stays.
    @Test func aRowAddsTheBooksTagExactly() async throws {
        try await withFileTags(["#x", " spaced"]) { book, scene in
            step(book, scene) { #expect(book.removeTag("#x", from: scene)) }
            step(book, scene) { #expect(book.removeTag(" spaced", from: scene)) }
            try #require(tags(book, scene).isEmpty, "precondition")
            step(book, scene) { #expect(book.toggleTag("#x", on: scene)) }
            step(book, scene) { #expect(book.toggleTag(" spaced", on: scene)) }
            #expect(tags(book, scene) == ["#x", " spaced"])
        }
    }

    /// Removing the tag at index 1, adding another, then undoing both leaves the tags as they
    /// were, in order.
    @Test func undoingARemoveAndAnAddRestoresTheOrder() async throws {
        try await withTags { book, scene, _ in
            step(book, scene) { #expect(book.addTag("storm", to: scene)) }
            book.pageUndo(for: scene).removeAllActions()
            try #require(tags(book, scene) == ["Mara", "clue", "storm"], "precondition")
            let undo = book.pageUndo(for: scene)
            step(book, scene) { #expect(book.removeTag("clue", from: scene)) }
            step(book, scene) { #expect(book.addTag("fog", to: scene)) }
            #expect(tags(book, scene) == ["Mara", "storm", "fog"])
            undo.undo()
            #expect(tags(book, scene) == ["Mara", "storm"])
            undo.undo()
            #expect(tags(book, scene) == ["Mara", "clue", "storm"])
            #expect(!undo.canUndo)
        }
    }

    @Test func addingIsOneUndoableStepNamedAddTag() async throws {
        try await withTags { book, scene, _ in
            let undo = book.pageUndo(for: scene)
            step(book, scene) { #expect(book.addTag("#storm", to: scene)) }
            #expect(tags(book, scene) == ["Mara", "clue", "storm"], "at the end, without its #")
            #expect(book.hasUnsavedEdits)
            #expect(undo.undoActionName == TagWording.addUndoName)
            undo.undo()
            #expect(tags(book, scene) == ["Mara", "clue"])
            #expect(undo.redoActionName == TagWording.addUndoName)
            undo.redo()
            #expect(tags(book, scene) == ["Mara", "clue", "storm"])
            #expect(undo.undoActionName == TagWording.addUndoName)
            #expect(!book.notesUndo(for: scene).canUndo && !book.titleUndo(for: scene).canUndo)
        }
    }

    /// The owner's rule (#20): a tag the book has in any case is added in the book's spelling.
    @Test func aTagTheBookHasTakesItsSpelling() async throws {
        try await withTags { book, scene, _ in
            step(book, scene) { #expect(book.addTag("Set Piece", to: scene)) }
            #expect(tags(book, scene) == ["Mara", "clue", "set piece"])
        }
    }

    @Test func aTagTheSceneHasInAnyCaseIsNotAddedAgain() async throws {
        try await withTags { book, scene, _ in
            let before = book.book
            #expect(!book.addTag("mara", to: scene))
            #expect(!book.addTag("#CLUE", to: scene))
            #expect(!book.addTag("  #  ", to: scene))
            #expect(book.book == before)
            #expect(!book.pageUndo(for: scene).canUndo)
        }
    }

    /// Removing puts the tag back where it was when undone.
    @Test func removingIsOneUndoableStepNamedRemoveTag() async throws {
        try await withTags { book, scene, _ in
            let undo = book.pageUndo(for: scene)
            step(book, scene) { #expect(book.removeTag("mara", from: scene)) }
            #expect(tags(book, scene) == ["clue"], "in any case")
            #expect(undo.undoActionName == TagWording.removeUndoName)
            undo.undo()
            #expect(tags(book, scene) == ["Mara", "clue"], "back in its place, in its spelling")
            #expect(undo.redoActionName == TagWording.removeUndoName)
            undo.redo()
            #expect(tags(book, scene) == ["clue"])
            #expect(!book.removeTag("storm", from: scene))
        }
    }

    @Test func togglingAddsOrRemoves() async throws {
        try await withTags { book, scene, _ in
            let undo = book.pageUndo(for: scene)
            step(book, scene) { #expect(book.toggleTag("set piece", on: scene)) }
            #expect(tags(book, scene) == ["Mara", "clue", "set piece"])
            #expect(undo.undoActionName == TagWording.addUndoName)
            step(book, scene) { #expect(book.toggleTag("Mara", on: scene)) }
            #expect(tags(book, scene) == ["clue", "set piece"])
            #expect(undo.undoActionName == TagWording.removeUndoName)
            undo.undo()
            #expect(undo.redoActionName == TagWording.removeUndoName)
            undo.undo()
            #expect(undo.redoActionName == TagWording.addUndoName)
            #expect(tags(book, scene) == ["Mara", "clue"])
        }
    }

    /// The book's list counts a tag change at once.
    @Test func theBooksTagsFollowEachEdit() async throws {
        try await withTags { book, scene, _ in
            #expect(book.tags.entries.map(\.tag) == ["clue", "Mara", "set piece"])
            step(book, scene) { #expect(book.addTag("set piece", to: scene)) }
            #expect(book.tags.entries.first == BookTags.Entry(tag: "set piece", scenes: 2))
        }
    }

    /// A tag edit is an edit like any other: autosave writes it to `book.md`'s `tags:` line.
    @Test func aTagEditReachesBookMD() async throws {
        try await withTags { book, scene, url in
            step(book, scene) { #expect(book.addTag("red, door", to: scene)) }
            book.saveNow()
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scene(scene)?.tags == ["Mara", "clue", "red, door"])
            let text = String(decoding: try Data(contentsOf: url.appending(path: "book.md")), as: UTF8.self)
            #expect(text.contains("tags: Mara, clue, red\\, door\n"), "the comma escaped (§2.2)")
            step(book, scene) { #expect(book.removeTag("clue", from: scene)) }
            book.saveNow()
            await eventually { book.status == .saved }
            #expect(try bookOnDisk(url).scene(scene)?.tags == ["Mara", "red, door"])
        }
    }

    @Test func aReadOnlyBookRefusesEveryTagEdit() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Held.sceneit")
            let holder = try BookPackage.create(at: url, title: "Held")
            var ids = IDGenerator.system
            let held = BookScene(
                id: ids.sceneID(), modified: Timestamp(secondsSince1970: 1_700_000_000, offset: .zero),
                title: "One", tags: ["Mara"])
            _ = try holder.package.save(Book(title: "Held", scenes: [held]))
            let store = makeStore(in: folder)
            #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            let book = try #require(store.current)
            let before = book.book
            #expect(!book.addTag("clue", to: held.id))
            #expect(!book.removeTag("Mara", from: held.id))
            #expect(!book.toggleTag("Mara", on: held.id))
            #expect(book.book == before)
            #expect(!book.pageUndo(for: held.id).canUndo)
            #expect(await store.closeBook() == .left)
            withExtendedLifetime(holder) {}
        }
    }
}
