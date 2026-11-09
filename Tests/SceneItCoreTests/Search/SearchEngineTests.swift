import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// PLAN M5 (c) and (d), and the engine's contract: units from a book, the tags option, progressive
/// updates and cancellation.
@Suite struct SearchEngineTests {
    private static let created = Timestamp(secondsSince1970: 0, offset: .zero)

    @Test func bearClawFindsBearPawAsANearMatch() async throws {
        let units = bodyUnits(["The bear paw prints led north.", "A wolf howled."])
        let update = try await finalUpdate(units, "bear claw")
        #expect(update.quality == .near)
        let hit = try #require(hits(update).first)
        #expect(hit.unit.text == "The bear paw prints led north.")
        #expect(highlighted(hit, .match) == ["bear"])
        #expect(highlighted(hit, .differs) == ["paw"])
    }

    @Test func differingWordsSitWhereTheMissingKeywordsWouldBe() async throws {
        let units = bodyUnits(["Her old brown bear. Paw prints."])
        let hit = try #require(hits(try await finalUpdate(units, "grey wolf bear claw")).first)
        #expect(highlighted(hit, .match) == ["bear"])
        #expect(highlighted(hit, .differs) == ["old", "brown"], "not \"Paw\": it's in the next sentence")
    }

    @Test func anExactMatchAnywhereHidesThePartialOnes() async throws {
        let units = bodyUnits(["The bear paw prints.", "A bear claw mark."])
        let update = try await finalUpdate(units, "bear claw")
        #expect(update.quality == .exact)
        #expect(hits(update).map(\.unit.text) == ["A bear claw mark."])
        #expect(hits(update).allSatisfy { !$0.highlights.contains { $0.kind == .differs } })
    }

    private func book() -> Book {
        let comment = Comment(
            id: CommentID(rawValue: "c1"), color: .blue, text: "Is the otter\nreal?", created: Self.created)
        return Book(
            title: "Book",
            scenes: [
                BookScene(
                    id: SceneID(rawValue: "s1"), modified: Self.created, title: "The ferry",
                    tags: ["opening", "Mara"],
                    body: [[Run("He saw the otter.")], [], [Run("Mara "), Run("waved", styles: [.italic])]],
                    notes: [[Run("Check the otter's name.")]], comments: [comment]),
                BookScene(
                    id: SceneID(rawValue: "s2"), modified: Self.created, title: "Harbor",
                    body: [[Run("Gulls.")]]),
            ],
            boneyard: [
                BookScene(
                    id: SceneID(rawValue: "cut"), modified: Self.created, title: "The station",
                    body: [[Run("An otter at the station.")]])
            ])
    }

    @Test func aBookYieldsEveryNonEmptyUnitInBookOrder() {
        let units = SearchUnit.units(of: book(), version: .working)
        #expect(
            units.map(\.field) == [
                .title, .body(paragraph: 0), .body(paragraph: 2), .notes(paragraph: 0),
                .comment(CommentID(rawValue: "c1")), .tags, .title, .body(paragraph: 0), .title,
                .body(paragraph: 0),
            ])
        #expect(units[2].text == "Mara waved")
        #expect(units[5].text == "opening\nMara")
        #expect(
            units.compactMap(\.scene?.placement) == Array(repeating: .story(number: 1), count: 6) + [
                .story(number: 2), .story(number: 2), .boneyard, .boneyard,
            ])
        #expect(units.allSatisfy { $0.version == .working })
        #expect(units.last?.scene?.title == "The station")
    }

    @Test func boneyardScenesAreSearchedAndMarked() async throws {
        let update = try await finalUpdate(SearchUnit.units(of: book(), version: .working), "otter")
        let placements = update.scenes.compactMap(\.best.unit.scene?.placement)
        #expect(Set(placements) == [.story(number: 1), .boneyard])
        let fields = Set(hits(update).map(\.unit.field))
        #expect(fields == [.body(paragraph: 0), .notes(paragraph: 0), .comment(CommentID(rawValue: "c1"))])
    }

    @Test func tagsAreSearchedOnlyWithSearchTags() async throws {
        let units = SearchUnit.units(of: book(), version: .working)
        let without = try await finalUpdate(units, "opening")
        #expect(without.scenes.isEmpty)
        let with = try await finalUpdate(units, "opening", .searchTags)
        #expect(hits(with).map(\.unit.field) == [.tags])
        #expect(highlighted(try #require(hits(with).first)) == ["opening"])
        let mara = try await finalUpdate(units, "mara")
        #expect(
            hits(mara).map(\.unit.field) == [.body(paragraph: 2)],
            "the tag Mara isn't found without the option")
    }

    private func taggedUnits(_ tags: [String]) -> [SearchUnit] {
        let scene = BookScene(
            id: SceneID(rawValue: "s1"), modified: Self.created, title: "Untitled", tags: tags, body: [])
        return SearchUnit.units(of: Book(title: "Book", scenes: [scene]), version: .working)
            .filter { $0.field == .tags }
    }

    @Test func aPhraseMatchesWithinOneTagButNeverAcrossTwo() async throws {
        let across = taggedUnits(["red", "door", "blue"])
        #expect(across.map(\.text) == ["red\ndoor\nblue"])
        let words = try #require(hits(try await finalUpdate(across, "red door", .searchTags)).first)
        #expect(highlighted(words) == ["red", "door"], "precondition: both words are in the tag set")
        #expect(try await finalUpdate(across, "\"red door\"", .searchTags).scenes.isEmpty)

        let within = taggedUnits(["blue", "red door"])
        let phrase = try #require(hits(try await finalUpdate(within, "\"red door\"", .searchTags)).first)
        #expect(highlighted(phrase) == ["red door"])
        #expect(phrase.highlights.map(\.range) == [5..<13])
    }

    @Test func tagHighlightsFallOnTheirOwnTag() async throws {
        let units = taggedUnits(["opening", "Mara's boat", "doors"])
        let hit = try #require(hits(try await finalUpdate(units, "door mara boat", .searchTags)).first)
        #expect(hit.unit.text == "opening\nMara's boat\ndoors")
        #expect(highlighted(hit) == ["Mara's", "boat", "doors"])
        #expect(hit.highlights.map(\.range) == [8..<14, 15..<19, 20..<25])
        #expect(hit.rank.tier == .paragraph, "each tag is its own sentence")
    }

    @Test func updatesArriveProgressivelyAndEndComplete() async throws {
        let units = bodyUnits((0..<4).map { "bear \($0)" })
        let all = await updates(KeywordSearch(units: units, updateInterval: .zero), SearchQuery("bear"))
        #expect(
            all.map(\.progress) == [
                .searching(unitsSearched: 1, of: 4), .searching(unitsSearched: 2, of: 4),
                .searching(unitsSearched: 3, of: 4), .complete,
            ])
        #expect(all.map(\.hitCount) == [1, 2, 3, 4])
    }

    @Test func progressCountsOnlyTheUnitsSearched() async throws {
        let units = [
            unit("bear", field: .body(paragraph: 0)), unit("bear", field: .tags), unit("bear", field: .title),
        ]
        let all = await updates(KeywordSearch(units: units, updateInterval: .zero), SearchQuery("bear"))
        #expect(
            all.map(\.progress) == [
                .searching(unitsSearched: 1, of: 2), .searching(unitsSearched: 1, of: 2), .complete,
            ])
    }

    @Test func cancellingTheAwaitingTaskEndsTheSearchAtTheNextBatch() async throws {
        let index = KeywordSearch(units: bodyUnits((0..<100).map { "bear \($0)" }), updateInterval: .zero)
        let received = await Task {
            var received: [SearchUpdate] = []
            for await update in index.search(SearchQuery("bear")) {
                received.append(update)
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return received
        }.value
        #expect(received.map(\.progress) == [.searching(unitsSearched: 1, of: 100)])
    }

    /// The iterator checks nothing itself, so this shows the check sits in the loop over units,
    /// inside a single long step: cancelled before the step, or while it reads any unit but the
    /// last, the step reads no further unit and reports nothing.
    @Test(arguments: 0..<3) func aCancelledSearchReadsNoFurtherUnit(unitsRead: Int) async {
        let index = KeywordSearch(units: bodyUnits(["bear", "bear", "bear"]), updateInterval: .seconds(3600))
        let query = SearchQuery("bear")
        var uncancelled = SearchRun(index: index, query: query)
        #expect(
            uncancelled.advance(on: ManualClock())?.progress == .complete,
            "precondition: one step reads every unit")

        let clock = CancellingClock(onRead: unitsRead + 1)
        let (update, searched) = await Task {
            var run = SearchRun(index: index, query: query)
            let update = run.advance(on: clock)
            return (update, run.unitsSearched)
        }.value
        #expect(update == nil)
        #expect(searched == unitsRead)
    }

    @Test func aSearchIndexIsUsableAsAnExistential() async throws {
        let index: any SearchIndex = KeywordSearch(units: bodyUnits(["a bear"]))
        var last: SearchUpdate?
        for await update in index.search(SearchQuery("bear")) { last = update }
        #expect(last?.hitCount == 1)
    }

    @Test func theIndexCanBeBuiltConcurrently() async {
        let index = await KeywordSearch.indexing(bodyUnits(["a bear"]))
        #expect(index.units.count == 1)
    }
}
