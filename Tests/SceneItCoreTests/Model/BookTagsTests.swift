import Foundation
import Testing

@testable import SceneItCore

private func scene(_ title: String, _ tags: [String]) -> BookScene {
    var ids = IDGenerator.system
    return BookScene(
        id: ids.sceneID(), modified: Timestamp(secondsSince1970: 0, offset: .zero), title: SceneTitle(title),
        tags: tags)
}

private func entries(_ tags: BookTags) -> [String] {
    tags.entries.map { "\($0.tag) \($0.scenes)" }
}

/// The Tags tab's list of the book's tags (PLAN §8.3, #20): every tag of the story and the
/// Boneyard, with how many scenes use it, most-used first, ties alphabetical ignoring case; and
/// a typed tag's spelling.
@Suite struct BookTagsTests {
    /// The mockup's list (06-tags-tab.png), with a Boneyard scene among those counted.
    @Test func theMockupsTagsSortByCountThenAlphabetically() {
        let book = Book(
            title: "Novel",
            scenes: [
                scene("The ferry", ["opening", "Mara"]), scene("Arrival", ["Mara", "island"]),
                scene("The letter", ["clue", "mother", "Mara"]), scene("Market day", ["clue"]),
                scene("Storm warning", ["storm", "set piece"]), scene("What the tide left", ["mother"]),
                scene("Fog", []),
            ],
            boneyard: [scene("The brother", ["Tomas", "clue"])])
        #expect(
            entries(BookTags(book)) == [
                "clue 3", "Mara 3", "mother 2", "island 1", "opening 1", "set piece 1", "storm 1", "Tomas 1",
            ])
    }

    /// `Tomas` sorts after `storm`, and `apple` before `Banana`: ties ignore case, so capitals
    /// don't all come first as they would in code-point order.
    @Test func tiesAreAlphabeticalIgnoringCase() {
        let book = Book(
            title: "Novel", scenes: [scene("One", ["Tomas", "storm", "Banana", "apple", "Zed", "yak"])])
        #expect(entries(BookTags(book)) == ["apple 1", "Banana 1", "storm 1", "Tomas 1", "yak 1", "Zed 1"])
        #expect(
            ["Tomas", "storm"].sorted() == ["Tomas", "storm"],
            "precondition: code-point order would put Tomas first")
    }

    @Test func aTagOnlyTheBoneyardUsesIsListedAndCounted() {
        let book = Book(
            title: "Novel", scenes: [scene("One", ["dream"])],
            boneyard: [scene("Cut", ["dream", "ghost"]), scene("Cut too", ["ghost"])])
        #expect(entries(BookTags(book)) == ["dream 2", "ghost 2"])
    }

    /// Scenes deleted from the Boneyard are never shown (ADR 0031), so their tags aren't either.
    @Test func aDeletedScenesTagsAreNotListed() {
        var book = Book(title: "Novel", scenes: [scene("One", ["kept"])], boneyard: [scene("Cut", ["gone"])])
        let cut = book.boneyard[0].id
        let deleted = book.delete(cut, from: .boneyard)
        #expect(deleted != nil)
        #expect(book.deleted.count == 1, "precondition: the scene is in the file's Deleted part")
        #expect(entries(BookTags(book)) == ["kept 1"])
    }

    /// Tags that differ only in case are one tag, counted once per scene, in the spelling the
    /// most scenes use.
    @Test func caseVariantsAreOneTagInTheMostUsedSpelling() {
        let book = Book(
            title: "Novel",
            scenes: [
                scene("One", ["mara"]), scene("Two", ["MARA"]), scene("Three", ["mara"]),
                scene("Four", ["Mara", "mara"]),
            ])
        #expect(entries(BookTags(book)) == ["mara 4"], "Four has it twice, and counts once")
    }

    /// With as many scenes for each, the spelling first in code-point order wins, so a
    /// capitalized name wins over its lowercase slip.
    @Test func aTieBetweenSpellingsGoesToTheFirstInCodePointOrder() {
        let book = Book(title: "Novel", scenes: [scene("One", ["mara"]), scene("Two", ["Mara"])])
        #expect(entries(BookTags(book)) == ["Mara 2"])
        let reversed = Book(title: "Novel", scenes: [scene("One", ["Mara"]), scene("Two", ["mara"])])
        #expect(entries(BookTags(reversed)) == ["Mara 2"], "whatever the scenes' order")
    }

    @Test func anEmptyBookHasNoTags() {
        #expect(BookTags(Book(title: "Novel", scenes: [scene("One", [])])).entries.isEmpty)
    }

    /// The owner's rule (#20): a typed tag the book has in any case takes the book's spelling.
    @Test func aTypedTagTakesTheBooksSpelling() {
        let tags = BookTags(Book(title: "Novel", scenes: [scene("One", ["Mara", "set piece"])]))
        #expect(tags.spelling(of: "mara") == "Mara")
        #expect(tags.spelling(of: "#MARA") == "Mara")
        #expect(tags.spelling(of: "Set Piece") == "set piece")
        #expect(tags.spelling(of: "Tomas") == "Tomas", "a new tag as typed")
        #expect(tags.spelling(of: " # ") == nil)
    }

    @Test(arguments: [
        ("#opening", "opening"), ("  #opening  ", "opening"), ("##opening", "#opening"),
        ("# opening", "opening"),
        ("set piece", "set piece"), ("mid#hash", "mid#hash"), ("caf\u{00E9}", "cafe"),
        ("red\ndoor", "red door"),
    ])
    func aTypedTagLosesItsHashAndSpacesAndIsAdmitted(typed: String, tag: String) {
        #expect(SceneTag.typed(typed) == tag)
    }

    @Test(arguments: ["", "   ", "#", " #  "])
    func nothingLeftIsNoTag(typed: String) {
        #expect(SceneTag.typed(typed) == nil)
    }

    @Test func aSceneHoldsATagInAnyCase() {
        #expect(SceneTag.contains(["Mara", "clue"], "mara"))
        #expect(!SceneTag.contains(["Mara", "clue"], "Tomas"))
    }

    /// The scene's tags as `book.md` reads a `tags:` line holding `item`.
    private func fileTags(_ item: String) -> [String]? {
        parse(
            "---\ntitle: T\nformat: 2\n---\n\n## S\nid: s1\nmodified: 2026-01-01T00:00:00+00:00\n"
                + "tags: \(item)\n\nBody.\n"
        ).book.scenes.first?.tags
    }

    /// Typing drops one leading `#` as the file does, so the typed text and the same text in a
    /// `tags:` line give one tag, which saves and reads back unchanged.
    @Test(arguments: ["#x", "##x", "x"])
    func aTypedTagReadsAsTheFileWouldReadIt(typed: String) throws {
        let tag = try #require(SceneTag.typed(typed))
        #expect(fileTags(typed) == [tag])
        let book = Book(title: "T", scenes: [scene("S", [tag])])
        var ids = IDGenerator.system
        let reread = BookFormat.parse(
            try BookFormat.verifiedSerialization(of: book), opened: BookFormat.rereadTime, ids: &ids)
        #expect(reread.book.scenes.first?.tags == [tag], "saved and read back")
    }

    /// The one difference: typing also trims the spaces after the `#`, where the file keeps them.
    @Test func typingTrimsAfterTheHashWhereTheFileKeepsTheSpace() {
        #expect(SceneTag.typed("# x") == "x")
        #expect(fileTags("# x") == [" x"])
    }

    /// The file's ` x` (a tag that starts with a space) saves and reads back unchanged.
    @Test func aTagWithALeadingSpaceSavesAndReadsBack() throws {
        let book = Book(title: "T", scenes: [scene("S", [" x"])])
        try #require(book.scenes.first?.tags == [" x"], "precondition: the model keeps the space")
        var ids = IDGenerator.system
        let reread = BookFormat.parse(
            try BookFormat.verifiedSerialization(of: book), opened: BookFormat.rereadTime, ids: &ids)
        #expect(reread.book.scenes.first?.tags == [" x"])
    }

    /// The ⌕'s search: one word as it is; words in one sentence as a phrase, a `"` in them a
    /// space; words a sentence break separates as words; and nothing for a tag with no word.
    @Test func theSearchForATag() {
        #expect(SceneTag.searchText("Mara") == "Mara")
        #expect(SceneTag.searchText("set piece") == "\"set piece\"")
        #expect(SceneTag.searchText("set-piece") == "\"set-piece\"")
        #expect(SceneTag.searchText("say \"hi\"") == "\"say  hi \"")
        #expect(SceneTag.searchText("Mr. Smith") == "Mr. Smith")
        #expect(SceneTag.searchText("!!") == nil)
        #expect(SearchQuery(SceneTag.searchText("set piece") ?? "").keywords == [.phrase(["set", "piece"])])
        #expect(
            SearchQuery(SceneTag.searchText("Mr. Smith") ?? "").keywords.count == 2, "two words, no phrase")
    }
}
