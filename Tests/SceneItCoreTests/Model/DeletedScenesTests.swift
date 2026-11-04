import Foundation
import Testing

@testable import SceneItCore

/// ADR 0031: a scene deleted from the Boneyard stays in the file, in its Deleted section
/// (book format §1.9), and the writer is never shown it: not in search, counts or navigation.
@Suite struct DeletedScenesTests {
    static let dream = SceneID(rawValue: "dream")

    /// Every field of the deleted scene holds "zebra", and nothing else does.
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

        # Deleted

        ## The zebra dream
        id: dream
        modified: 2026-01-01T00:00:00+00:00
        tags: zebra

        A zebra dreamed of nine more.

        ### Notes
        Cut the zebra?

        ### Comments
        - c1 | red | 2026-01-01T00:00:00+00:00 | c0-7 | "A zebra" | Is a zebra too much?

        """

    private func book() throws -> Book {
        let parsed = parse(Self.text)
        try #require(parsed.newEntries.isEmpty, "precondition: the file is clean")
        return parsed.book
    }

    @Test func theDeletedSectionReadsIntoItsOwnListAndBackByteForByte() throws {
        let book = try book()
        #expect(book.scenes.map(\.id.rawValue) == ["ferry"])
        #expect(book.boneyard.map(\.id.rawValue) == ["brother"])
        #expect(book.deleted.map(\.id) == [Self.dream])
        let dream = try #require(book.deleted.first)
        #expect(dream.tags == ["zebra"] && !dream.notes.isEmpty && dream.comments.count == 1)
        #expect(try BookFormat.verifiedSerialization(of: book) == Data(Self.text.utf8))
    }

    @Test func searchNeverFindsADeletedScene() async throws {
        var book = try book()
        #expect(SearchUnit.units(of: book, version: .working).allSatisfy { $0.scene != Self.dream })
        let none = try await finalUpdate(SearchUnit.units(of: book, version: .working), "zebra", .searchTags)
        #expect(none.scenes.isEmpty)

        _ = book.undelete(Self.dream, toBoneyardAt: 0)
        let found = try await finalUpdate(SearchUnit.units(of: book, version: .working), "zebra", .searchTags)
        #expect(
            Set(hits(found).map(\.unit.field))
                == [
                    .title, .body(paragraph: 0), .notes(paragraph: 0), .comment(CommentID(rawValue: "c1")),
                    .tags,
                ],
            "precondition: the query finds every field of the scene once it's in the Boneyard")
    }

    @Test func countsLeaveDeletedScenesOut() throws {
        let book = try book()
        let dream = try #require(book.deleted.first)
        #expect(
            dream.wordCount.words > 0 && !dream.comments.isEmpty, "precondition: there's something to count")
        var withoutDeleted = book
        withoutDeleted.deleted = []

        let counts = SceneWordCounts(book)
        #expect(counts[Self.dream] == .zero, "a deleted scene isn't counted at all")
        #expect(counts.manuscript(of: book) == book.scenes[0].wordCount)
        #expect(FiledCopyCounts(book) == FiledCopyCounts(withoutDeleted))
        #expect(
            FiledCopyCounts(filedBytes: Data(Self.text.utf8)) == FiledCopyCounts(withoutDeleted),
            "a filed copy's counts")
    }

    @Test func theWriterCantReachADeletedScene() throws {
        let book = try book()
        try #require(book.deleted.contains { $0.id == Self.dream }, "precondition: the scene is in the book")
        #expect(book.scene(Self.dream) == nil)
        #expect(SceneLocation(of: Self.dream, in: book) == .noScene)
        #expect(book.visiblePlace(of: Self.dream) == nil)
        #expect(!book.visibleScenes.contains { $0.id == Self.dream })

        var restored = book
        _ = restored.undelete(Self.dream, toBoneyardAt: 0)
        let dream = try #require(restored.scene(Self.dream), "back in the Boneyard, it's reachable again")
        #expect(SceneLocation(of: Self.dream, in: restored) == .boneyard(dream))
        #expect(restored.visibleScenes.map(\.id.rawValue) == ["ferry", "dream", "brother"])
    }

    @Test func aDeletedScenesErrorsAreListedLastUnderItsName() throws {
        let damaged = Self.text.replacingOccurrences(of: "tags: zebra", with: "tags: zebra\nmood: grim")
        let book = parse(damaged).book
        let group = try #require(book.errorGroups.last)
        #expect(group.owner == .scene(Self.dream))
        #expect(group.refs.map(\.entry) == [ErrorEntry(.metadata, "mood: grim")])
        #expect(ErrorsWording.group(group.owner, in: book) == "Deleted › The zebra dream")
        #expect(BookFormat.reason(for: group.refs[0], in: book) == .metadata(.unknownKey))
    }

    @Test func aFixCantGiveAnotherSceneADeletedScenesID() throws {
        let text = Self.text.replacingOccurrences(
            of: "Mara took the ferry.", with: "Mara took the ferry.\n\n### Unparsed\n- [metadata] id: dream")
        let book = parse(text).book
        let ref = try #require(
            book.errorGroups.flatMap(\.refs).first { $0.owner == .scene(SceneID(rawValue: "ferry")) })
        guard case .repaired? = BookFormat.repair(ref, as: "id: fresh", in: book) else {
            Issue.record("precondition: an unused id repairs")
            return
        }
        guard case .kept(_, let reason)? = BookFormat.repair(ref, as: "id: dream", in: book) else {
            Issue.record("a deleted scene's id was given away")
            return
        }
        #expect(reason == .metadata(.idInUse))
    }

    @Test func verificationRefusesADeletedSceneThatSharesAnID() throws {
        var book = try book()
        book.deleted.append(book.scenes[0])
        #expect(throws: VerificationFailure.self) { try BookFormat.verifiedSerialization(of: book) }
    }

    @Test func deletingMovesABoneyardSceneToTheTopOfTheDeletedSection() throws {
        let original = try book()
        var book = original
        let brother = book.boneyard[0]
        let story = book.delete(fromBoneyard: book.scenes[0].id)
        let again = book.delete(fromBoneyard: Self.dream)
        #expect(story == nil, "only a Boneyard scene can be deleted")
        #expect(again == nil, "nor one that's already deleted")
        #expect(book == original)

        let index = book.delete(fromBoneyard: brother.id)
        #expect(index == 0)
        #expect(book.boneyard.isEmpty)
        #expect(book.deleted.map(\.id) == [brother.id, Self.dream])
        #expect(book.deleted[0] == brother, "it keeps its id, text and everything else")
        let bytes = try BookFormat.verifiedSerialization(of: book)
        #expect(parse(bytes).book == book)
        #expect(
            !String(decoding: bytes, as: UTF8.self).contains("# Boneyard"), "an empty Boneyard isn't written")

        let restored = book.undelete(brother.id, toBoneyardAt: 0)
        #expect(restored)
        #expect(book == original)
        let twice = book.undelete(brother.id, toBoneyardAt: 0)
        #expect(!twice)
    }

    /// The owner's approved wording (#94), with Cancel first so Return keeps the scene.
    @Test func theDeleteConfirmationNamesTheSceneAndSaysItsKept() throws {
        let alert = BoneyardWording.confirmDelete(try book().boneyard[0])
        #expect(alert.title == "Delete “The brother” from the Boneyard?")
        #expect(
            alert.message
                == "It's kept at the end of the book file, where you can recover it with a text editor.")
        #expect(alert.buttons.map(\.label) == ["Cancel", "Delete"])
        #expect(alert.choices == [.cancel, .delete])
    }
}
