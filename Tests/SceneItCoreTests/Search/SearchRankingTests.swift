import Foundation
import Testing

@testable import SceneItCore

/// PLAN M5 (b): coverage > sentence > paragraph > fine score. Each test pins one tier against the
/// next by giving the unit that should lose the better score on every later criterion, and
/// asserts that it does, so the test can't pass by accident.
@Suite struct SearchRankingTests {
    private func rankedHits(_ units: [SearchUnit], _ text: String, _ options: SearchOptions = [])
        async throws -> [SearchHit]
    {
        try await hits(finalUpdate(units, text, options))
    }

    private func hit(_ hits: [SearchHit], _ text: String) throws -> SearchHit {
        try #require(hits.first { $0.unit.text == text })
    }

    @Test func coverageBeatsProximityAndFineScore() async throws {
        let wide = "The bear slept. The claw was sharp."
        let strong = "Bear bear bear"
        let units =
            [unit(wide, field: .body(paragraph: 0), scene: "a"), unit(strong, field: .title, scene: "b")]
            + (0..<10).map { unit("a claw \($0)", field: .body(paragraph: $0), scene: "c") }
        let hits = try await rankedHits(units, "bear claw wolf")
        let (first, second) = (try hit(hits, wide), try hit(hits, strong))
        #expect(first.rank.coverage == 2 && first.rank.tier == .paragraph, "precondition")
        #expect(second.rank.coverage == 1 && second.rank.tier == .sentence, "precondition")
        #expect(second.rank.fine > first.rank.fine, "precondition")
        #expect(first.rank > second.rank)
        #expect(hits.first?.unit.text == wide)
    }

    @Test func theSameSentenceBeatsTheSameParagraphAndFineScore() async throws {
        let sentence = "The bear had a long, sharp, curved claw."
        let paragraph = "Bear bear bear. Claw claw claw."
        let units = [
            unit(sentence, field: .body(paragraph: 0), scene: "a"),
            unit(paragraph, field: .title, scene: "b"),
        ]
        let hits = try await rankedHits(units, "bear claw")
        let (first, second) = (try hit(hits, sentence), try hit(hits, paragraph))
        #expect(first.rank.coverage == second.rank.coverage, "precondition")
        #expect(first.rank.tier == .sentence && second.rank.tier == .paragraph, "precondition")
        #expect(second.rank.fine > first.rank.fine, "precondition")
        #expect(hits.map(\.unit.text) == [sentence, paragraph])
    }

    /// Two units with the same coverage, tier, rarity and field, differing only as `better` and
    /// `worse` do.
    private func expectFineOrder(_ better: String, over worse: String, query: String) async throws {
        let units = [
            unit(better, field: .body(paragraph: 0), scene: "a"),
            unit(worse, field: .body(paragraph: 0), scene: "b"),
        ]
        let hits = try await rankedHits(units, query)
        let (first, second) = (try hit(hits, better), try hit(hits, worse))
        #expect(
            first.rank.coverage == second.rank.coverage && first.rank.tier == second.rank.tier, "precondition"
        )
        #expect(first.rank.fine > second.rank.fine)
        #expect(hits.map(\.unit.text) == [better, worse])
    }

    @Test func aSmallerSpanScoresHigher() async throws {
        try await expectFineOrder(
            "a bear and a claw", over: "a bear went far away from a claw", query: "bear claw")
    }

    @Test func theQueryWordOrderScoresHigher() async throws {
        try await expectFineOrder("the bear claw", over: "the claw bear", query: "bear claw")
    }

    @Test func repeatsScoreHigherWithDiminishingReturns() async throws {
        try await expectFineOrder("bear and bear", over: "bear and wolf", query: "bear")
        let units = (1...4).map { count in
            unit(
                Array(repeating: "bear", count: count).joined(separator: " "), field: .body(paragraph: 0),
                scene: "\(count)")
        }
        let scores = try await rankedHits(units, "bear").sorted { $0.unit.text < $1.unit.text }.map(
            \.rank.fine.value)
        let gains = zip(scores.dropFirst(), scores).map { $0 - $1 }
        #expect(gains.allSatisfy { $0 > 0 })
        #expect(gains == gains.sorted(by: >), "each repeat adds less: \(gains)")
    }

    @Test func rarerKeywordsScoreHigher() async throws {
        let units =
            [
                unit("a claw", field: .body(paragraph: 0), scene: "a"),
                unit("a bear", field: .body(paragraph: 0), scene: "b"),
            ]
            + [unit("bear one", field: .body(paragraph: 0), scene: "c")]
        let hits = try await rankedHits(units, "bear claw")
        let (rare, common) = (try hit(hits, "a claw"), try hit(hits, "a bear"))
        #expect(
            rare.rank.coverage == common.rank.coverage && rare.rank.tier == common.rank.tier, "precondition")
        #expect(hits.first?.unit.text == "a claw")
    }

    @Test func titlesAndTagsAreBoosted() async throws {
        let units = [
            unit("the bear", field: .body(paragraph: 0), scene: "a"),
            unit("the bear", field: .title, scene: "b"),
            unit("the bear", field: .tags, scene: "c"),
        ]
        let hits = try await rankedHits(units, "bear", .searchTags)
        #expect(hits.map(\.unit.field) == [.title, .tags, .body(paragraph: 0)])
    }

    @Test func scenesAreOrderedByTheirBestUnitWithTheRestBehindIt() async throws {
        let units =
            bodyUnits(["a bear", "a bear", "a bear"], scene: "weak", number: 1)
            + [unit("The bear", field: .title, scene: "strong", number: 2)]
        let update = try await finalUpdate(units, "bear")
        #expect(update.scenes.map(\.scene.rawValue) == ["strong", "weak"])
        #expect(update.scenes.map(\.moreCount) == [0, 2])
        #expect(
            update.scenes[1].hits.map(\.unit.field) == [
                .body(paragraph: 0), .body(paragraph: 1), .body(paragraph: 2),
            ])
    }
}
