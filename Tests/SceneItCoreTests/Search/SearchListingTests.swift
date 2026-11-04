import Foundation
import Testing

@testable import SceneItCore

/// What the Search sheet lists and opens (#31): snippets, the near-match cap, and where a hit
/// leads in the book as it is now.
@Suite struct SearchListingTests {
    private static let rank = Rank(coverage: 1, tier: .sentence, fine: FineScore(value: 0))

    private static func hit(_ unit: SearchUnit, _ highlights: [(Range<Int>, Highlight.Kind)]) -> SearchHit {
        SearchHit(unit: unit, rank: rank, highlights: highlights.map { Highlight(range: $0.0, kind: $0.1) })
    }

    /// `word`'s first range in `text`.
    private static func range(of word: String, in text: String) throws -> Range<Int> {
        let found = (text as NSString).range(of: word)
        try #require(found.location != NSNotFound, "precondition: \(word) is in the text")
        return found.location..<(found.location + found.length)
    }

    private static func marked(_ snippet: SearchSnippet) -> [String] {
        snippet.highlights.map { (snippet.text as NSString).substring(with: NSRange($0.range)) }
    }

    // MARK: Snippets

    @Test func aMatchNearTheStartShowsTheWholeText() throws {
        let text = "The letter waited on the table."
        let snippet = SearchSnippet(Self.hit(unit(text, field: .body(paragraph: 0)), [(try Self.range(of: "letter", in: text), .match)]))
        #expect(snippet.text == text)
        #expect(Self.marked(snippet) == ["letter"])
    }

    @Test func aMatchFarInStartsAtAWordWithinTheContextAfterAnEllipsis() throws {
        let lead = (1...20).map { "word\($0)" }.joined(separator: " ")
        let text = lead + " and then the letter arrived."
        let match = try Self.range(of: "letter", in: text)
        try #require(match.lowerBound > SearchSnippet.leadingContext, "precondition: the match is far in")
        let snippet = SearchSnippet(Self.hit(unit(text, field: .body(paragraph: 0)), [(match, .match)]))

        #expect(snippet.text.hasPrefix(SearchSnippet.ellipsis))
        let shown = String(snippet.text.dropFirst(SearchSnippet.ellipsis.count))
        #expect(text.hasSuffix(shown), "the snippet is the end of the text")
        #expect(text.utf16.count - shown.utf16.count >= match.lowerBound - SearchSnippet.leadingContext)
        #expect(text.utf16.count - shown.utf16.count <= match.lowerBound, "the match is still shown")
        let cut = text.utf16.count - shown.utf16.count
        #expect(Array(text.utf16)[cut - 1] == UInt16(UInt8(ascii: " ")), "it starts at a word")
        #expect(Self.marked(snippet) == ["letter"], "the highlights moved with the cut")
    }

    @Test func tagsAreSplitAtTheirSeparatorWithTheirOwnHighlights() throws {
        let text = ["red door", "harbor", "old red"].joined(separator: SearchUnit.tagSeparator)
        let red = try Self.range(of: "red", in: text)
        let harbor = try Self.range(of: "harbor", in: text)
        let lastRed = (text as NSString).range(of: "red", options: .backwards)
        let hit = Self.hit(
            unit(text, field: .tags),
            [(red, .match), (harbor, .differs), (lastRed.location..<(lastRed.location + 3), .match)])
        let tags = SearchSnippet.tags(hit)
        #expect(tags.map(\.text) == ["red door", "harbor", "old red"])
        #expect(tags.map(Self.marked) == [["red"], ["harbor"], ["red"]])
        #expect(tags[1].highlights.map(\.kind) == [.differs])
    }

    // MARK: The near-match cap

    private static func update(scenes count: Int, _ quality: MatchQuality) -> SearchUpdate {
        let scenes = (0..<count).map { index in
            SceneHits(hits: [
                hit(unit("a bear", field: .body(paragraph: 0), scene: "s\(index)", number: index + 1), [(2..<6, .match)]),
                hit(unit("a bear", field: .body(paragraph: 1), scene: "s\(index)", number: index + 1), [(2..<6, .match)]),
            ])
        }
        return SearchUpdate(scenes: scenes, quality: quality, progress: .complete)
    }

    @Test func nearMatchesListTheBestScenesUntilAll() {
        let count = NearMatchLimit.bestCount + 5
        let update = Self.update(scenes: count, .near)
        let best = SearchListing(update, nearMatches: .best)
        #expect(best.scenes == Array(update.scenes.prefix(NearMatchLimit.bestCount)), "the best, in order")
        #expect(best.sceneCount == count)
        #expect(best.hitCount == 2 * count, "the counts are every hit, listed or not")
        #expect(best.hiddenSceneCount == 5)
        let all = SearchListing(update, nearMatches: .all)
        #expect(all.scenes == update.scenes)
        #expect(all.hiddenSceneCount == 0)
    }

    @Test func exactMatchesAndShortListsArentCapped() {
        let exact = Self.update(scenes: NearMatchLimit.bestCount + 5, .exact)
        #expect(SearchListing(exact, nearMatches: .best).hiddenSceneCount == 0)
        let few = Self.update(scenes: NearMatchLimit.bestCount, .near)
        #expect(SearchListing(few, nearMatches: .best).hiddenSceneCount == 0)
    }

    // MARK: Where a hit leads

    private static let created = Timestamp(secondsSince1970: 0, offset: .zero)

    private static func scene(title: String, body: [String], notes: [String] = []) -> BookScene {
        BookScene(
            id: SceneID(rawValue: "s1"), modified: created, title: SceneTitle(title),
            body: body.map { [Run($0)] }, notes: notes.map { [Run($0)] },
            comments: [Comment(id: CommentID(rawValue: "c1"), color: .purple, text: "Check it.", created: created)])
    }

    @Test func aBodyOrNotesHitSelectsItsMatchAfterTheParagraphsBeforeIt() throws {
        let scene = Self.scene(title: "Arrival", body: ["Dawn came.", "He found the letter."], notes: ["One.", "Two letters."])
        let body = Self.hit(unit("He found the letter.", field: .body(paragraph: 1)), [(13..<19, .match)])
        #expect(body.target(in: scene) == .text(.body, (11 + 13)..<(11 + 19)))
        let notes = Self.hit(unit("Two letters.", field: .notes(paragraph: 1)), [(4..<11, .match)])
        #expect(notes.target(in: scene) == .text(.notes, (5 + 4)..<(5 + 11)))
    }

    @Test func aTitleCommentOrTagsHitLeadsToItsField() {
        let scene = Self.scene(title: "The letter", body: ["Dawn."])
        #expect(Self.hit(unit("The letter", field: .title), [(4..<10, .match)]).target(in: scene) == .title(4..<10))
        let comment = CommentID(rawValue: "c1")
        #expect(Self.hit(unit("Check it.", field: .comment(comment)), [(0..<5, .match)]).target(in: scene) == .comment(comment))
        #expect(Self.hit(unit("harbor", field: .tags), [(0..<6, .match)]).target(in: scene) == .tags)
    }

    /// The book changed since the search: its offsets would select other words.
    @Test func aHitWhoseTextIsGoneSelectsNothing() {
        let scene = Self.scene(title: "Arrival", body: ["Dawn came.", "He found the note."])
        let edited = Self.hit(unit("He found the letter.", field: .body(paragraph: 1)), [(13..<19, .match)])
        #expect(edited.target(in: scene) == .scene)
        let gone = Self.hit(unit("Later.", field: .body(paragraph: 5)), [(0..<5, .match)])
        #expect(gone.target(in: scene) == .scene, "a paragraph that has gone")
        #expect(Self.hit(unit("Old title", field: .title), [(0..<3, .match)]).target(in: scene) == .scene)
        let dismissed = CommentID(rawValue: "c9")
        #expect(Self.hit(unit("Gone.", field: .comment(dismissed)), [(0..<4, .match)]).target(in: scene) == .scene)
        #expect(Self.hit(unit("One.", field: .notes(paragraph: 0)), [(0..<3, .match)]).target(in: scene) == .scene)
    }
}
