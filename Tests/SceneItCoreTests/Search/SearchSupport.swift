import Foundation
import Testing

@testable import SceneItCore

/// Units of one scene, `texts` as its body paragraphs.
func bodyUnits(_ texts: [String], scene: String = "s1", number: Int = 1) -> [SearchUnit] {
    texts.enumerated().map { index, text in
        unit(text, field: .body(paragraph: index), scene: scene, number: number)
    }
}

func unit(_ text: String, field: SearchField, scene: String = "s1", number: Int = 1) -> SearchUnit {
    SearchUnit(
        version: .working, scene: SceneID(rawValue: scene), sceneTitle: "Scene \(scene)",
        placement: .story(number: number), field: field, text: text)
}

/// Every update a search reports.
func updates(_ index: some SearchIndex, _ query: SearchQuery) async -> [SearchUpdate] {
    var updates: [SearchUpdate] = []
    for await update in index.search(query) { updates.append(update) }
    return updates
}

/// What a search finally reports, which must be complete.
func finalUpdate(_ units: [SearchUnit], _ text: String, _ options: SearchOptions = []) async throws
    -> SearchUpdate
{
    let last = try #require(
        await updates(KeywordSearch(units: units), SearchQuery(text, options: options)).last)
    #expect(last.progress == .complete)
    return last
}

/// The hits of `update`, best first.
func hits(_ update: SearchUpdate) -> [SearchHit] {
    update.scenes.flatMap(\.hits).sorted { $0.rank > $1.rank }
}

/// The text of each highlight of `kind`, in text order.
func highlighted(_ hit: SearchHit, _ kind: Highlight.Kind = .match) -> [String] {
    hit.highlights.filter { $0.kind == kind }.map {
        (hit.unit.text as NSString).substring(with: NSRange($0.range))
    }
}

/// The texts of the units found, best first.
func foundTexts(_ units: [SearchUnit], _ text: String, _ options: SearchOptions = []) async throws -> [String]
{
    try await hits(finalUpdate(units, text, options)).map(\.unit.text)
}

/// What a search finally reports, run on the calling thread, so that timing it measures the
/// engine and not the scheduling of `next()`.
func searchedToCompletion(_ index: KeywordSearch, _ query: SearchQuery) -> SearchUpdate {
    var run = SearchRun(index: index, query: query)
    while true {
        let update = run.advance()!
        if update.progress == .complete { return update }
    }
}
