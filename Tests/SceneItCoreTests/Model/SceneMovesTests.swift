import Testing

@testable import SceneItCore

private func scene(_ id: String) -> BookScene {
    BookScene(
        id: SceneID(rawValue: id), modified: Timestamp(secondsSince1970: 0, offset: .zero),
        title: SceneTitle(id))
}

private func ids(_ scenes: [BookScene]) -> [String] {
    scenes.map(\.id.rawValue)
}

private func id(_ raw: String) -> SceneID {
    SceneID(rawValue: raw)
}

extension Book {
    /// `relocate(_:to:)` on a copy: the copy, and where the scene was.
    fileprivate func relocating(_ id: SceneID, to place: ScenePlace) -> (book: Book, from: ScenePlace?) {
        var copy = self
        let from = copy.relocate(id, to: place)
        return (copy, from)
    }
}

/// The index arithmetic of moving, cutting and restoring scenes (PLAN §7.2, §7.3): where a slot
/// puts a scene, and that every move is undone by moving back to where it was.
@Suite struct SceneMovesTests {
    let book = Book(
        title: "Novel", scenes: ["a", "b", "c", "d"].map(scene), boneyard: ["x", "y"].map(scene))

    /// `change` applied to `book`, and then undone through the place it returned.
    private func applied(_ change: SceneChange) throws -> Book {
        let place = try #require(book.destination(of: change))
        let moved = book.relocating(change.scene, to: place)
        let from = try #require(moved.from)
        let undone = moved.book.relocating(change.scene, to: from)
        #expect(undone.from == place)
        #expect(undone.book == book, "moving back to where it was undoes it")
        return moved.book
    }

    @Test func movingLaterLandsJustBeforeTheSlotsScene() throws {
        #expect(ids(try applied(.move(id("a"), to: .before(id("c")))).scenes) == ["b", "a", "c", "d"])
        #expect(ids(try applied(.move(id("a"), to: .before(id("d")))).scenes) == ["b", "c", "a", "d"])
        #expect(ids(try applied(.move(id("b"), to: .end)).scenes) == ["a", "c", "d", "b"])
    }

    @Test func movingEarlierLandsJustBeforeTheSlotsScene() throws {
        #expect(ids(try applied(.move(id("d"), to: .before(id("a")))).scenes) == ["d", "a", "b", "c"])
        #expect(ids(try applied(.move(id("c"), to: .before(id("b")))).scenes) == ["a", "c", "b", "d"])
    }

    /// Dropped just before itself or just before the next scene, a scene stays where it is.
    @Test func aSlotNextToTheSceneChangesNothing() {
        for slot in [StorySlot.before(id("b")), .before(id("c"))] {
            let place = ScenePlace(part: .story, index: 1)
            #expect(book.destination(of: .move(id("b"), to: slot)) == place)
            #expect(book.relocating(id("b"), to: place) == (book, nil))
        }
        let end = ScenePlace(part: .story, index: 3)
        #expect(book.destination(of: .move(id("d"), to: .end)) == end)
        #expect(book.relocating(id("d"), to: end) == (book, nil))
    }

    @Test func cuttingPutsTheSceneAtTheFrontOfTheBoneyard() throws {
        let cut = try applied(.cut(id("c")))
        #expect(ids(cut.scenes) == ["a", "b", "d"])
        #expect(ids(cut.boneyard) == ["c", "x", "y"])
    }

    @Test func restoringPutsTheSceneInItsSlot() throws {
        let atEnd = try applied(.restore(id("y"), to: .end))
        #expect(ids(atEnd.scenes) == ["a", "b", "c", "d", "y"])
        #expect(ids(atEnd.boneyard) == ["x"])
        #expect(
            ids(try applied(.restore(id("x"), to: .before(id("a")))).scenes) == ["x", "a", "b", "c", "d"])
        #expect(
            ids(try applied(.restore(id("x"), to: .before(id("c")))).scenes) == ["a", "b", "x", "c", "d"])
    }

    /// A restore into an empty story, after every scene was cut.
    @Test func restoringIntoAnEmptyStory() throws {
        let empty = Book(title: "Novel", boneyard: [scene("x")])
        let place = try #require(empty.destination(of: .restore(id("x"), to: .end)))
        let restored = empty.relocating(id("x"), to: place)
        #expect(restored.from == ScenePlace(part: .boneyard, index: 0))
        #expect(ids(restored.book.scenes) == ["x"] && restored.book.boneyard.isEmpty)
    }

    @Test func aChangeOnlyAppliesToWhereTheSceneIs() {
        #expect(
            book.destination(of: .move(id("x"), to: .end)) == nil,
            "a Boneyard scene doesn't move in the story")
        #expect(book.destination(of: .cut(id("x"))) == nil, "it's cut already")
        #expect(book.destination(of: .restore(id("a"), to: .end)) == nil, "a story scene isn't restored")
        #expect(book.destination(of: .move(id("a"), to: .before(id("x")))) == nil, "a slot is in the story")
        #expect(book.destination(of: .cut(id("nowhere"))) == nil)
    }

    @Test func deletedScenesAreNeverMovedAndNothingMovesIntoTheDeletedSection() {
        let withDeleted = Book(title: "Novel", scenes: [scene("a")], deleted: [scene("gone")])
        #expect(
            withDeleted.relocating(id("gone"), to: ScenePlace(part: .story, index: 0)) == (withDeleted, nil))
        #expect(
            withDeleted.relocating(id("a"), to: ScenePlace(part: .deleted, index: 0)) == (withDeleted, nil))
    }

    @Test func aPlacePastEitherEndIsHeldToIt() throws {
        let last = book.relocating(id("a"), to: ScenePlace(part: .story, index: 99))
        #expect(ids(last.book.scenes) == ["b", "c", "d", "a"])
        let first = last.book.relocating(id("a"), to: ScenePlace(part: .story, index: -3))
        #expect(first.book == book)
    }

    /// Alt+Arrow's slot: the scene takes its neighbor's place, whichever side it's on.
    @Test func takingANeighborsPlace() throws {
        #expect(book.slot(takingThePlaceOf: id("b"), from: id("a")) == .before(id("c")))
        #expect(book.slot(takingThePlaceOf: id("d"), from: id("c")) == .end)
        #expect(book.slot(takingThePlaceOf: id("a"), from: id("b")) == .before(id("a")))
        #expect(book.slot(takingThePlaceOf: id("a"), from: id("d")) == .before(id("a")))
        #expect(book.slot(takingThePlaceOf: id("a"), from: id("a")) == nil)
        #expect(book.slot(takingThePlaceOf: id("x"), from: id("a")) == nil, "not in the story")

        let later = try #require(book.slot(takingThePlaceOf: id("c"), from: id("a")))
        #expect(ids(try applied(.move(id("a"), to: later)).scenes) == ["b", "c", "a", "d"])
        let earlier = try #require(book.slot(takingThePlaceOf: id("b"), from: id("d")))
        #expect(ids(try applied(.move(id("d"), to: earlier)).scenes) == ["a", "d", "b", "c"])
    }
}
