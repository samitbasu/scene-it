import Foundation
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
        #expect(units[5].text == "opening, Mara")
        #expect(
            units.map(\.placement) == Array(repeating: .story(number: 1), count: 6) + [
                .story(number: 2), .story(number: 2), .boneyard, .boneyard,
            ])
        #expect(units.allSatisfy { $0.version == .working })
        #expect(units.last?.sceneTitle == "The station")
    }

    @Test func boneyardScenesAreSearchedAndMarked() async throws {
        let update = try await finalUpdate(SearchUnit.units(of: book(), version: .working), "otter")
        let placements = update.scenes.map(\.best.unit.placement)
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
