import Foundation
import Testing

@testable import SceneItCore

/// A sanity check, not a benchmark (PLAN §9.2 targets about 100 ms for a 120,000-word working book
/// in a release build). A debug build is far slower, and other suites load the machine, so this
/// asserts only a generous ceiling and that doubling the input about doubles the time
/// (`expectLinear`).
@Suite struct SearchPerformanceTests {
    private static let queries = ["harbor gulls", "\"the island\"", "Mara watched the letter", "cafe zebra"]
        .map { SearchQuery($0) }

    @Test func aLongNovelIsSearchedQuickly() {
        let book = PerformanceTests.novel(words: 120_000)
        let words = book.scenes.flatMap(\.body).map(\.text).map { $0.split(separator: " ").count }.reduce(
            0, +)
        #expect(words >= 120_000, "precondition: a long novel")
        let units = SearchUnit.units(of: book, version: .working)
        let index = KeywordSearch(units: units)
        #expect(
            searchedToCompletion(index, SearchQuery("harbor gulls")).hitCount > 100,
            "precondition: the query matches throughout")

        let clock = ContinuousClock()
        let indexing = clock.measure { _ = KeywordSearch(units: units) }
        let searching = clock.measure { for query in Self.queries { _ = searchedToCompletion(index, query) } }
        print("search, \(words) words: index \(indexing), \(Self.queries.count) queries \(searching)")
        #expect(indexing + searching < .seconds(10))

        let unitsOfNovel = { (words: Int) in
            SearchUnit.units(of: PerformanceTests.novel(words: words), version: .working)
        }
        expectLinear("indexing", doubling: 60_000) { words in
            let units = unitsOfNovel(words)
            return { _ = KeywordSearch(units: units) }
        }
        expectLinear("searching", doubling: 60_000) { words in
            let index = KeywordSearch(units: unitsOfNovel(words))
            return { for query in Self.queries { _ = searchedToCompletion(index, query) } }
        }
    }

    /// A paragraph whose only window holding both keywords is the whole of it: `repeats` bears,
    /// then a claw. A window search that rescans the window as it shrinks is quadratic here.
    private static func bearsThenAClaw(_ repeats: Int, paragraph: Int = 0) -> SearchUnit {
        unit(String(repeating: "bear ", count: repeats) + "claw", field: .body(paragraph: paragraph))
    }

    @Test func aHugeParagraphIsSearchedInLinearTime() {
        let query = SearchQuery("bear claw")
        let found = searchedToCompletion(KeywordSearch(units: [Self.bearsThenAClaw(10_000)]), query)
        #expect(hits(found).first?.rank.coverage == 2, "precondition: one window holds both keywords")
        let scaling = expectLinear("one paragraph", doubling: 10_000) { repeats in
            let index = KeywordSearch(units: [Self.bearsThenAClaw(repeats)])
            return { _ = searchedToCompletion(index, query) }
        }
        print("search, one paragraph of 10,000 and 20,000 words: \(scaling)")
    }

    /// Timing alone can't place the cancellation mid-search on a loaded machine, so this test
    /// asserts only that stopping is prompt; `aCancelledSearchReadsNoFurtherUnit` pins where
    /// cancellation is checked.
    @Test func cancellingStopsASearchOfHugeParagraphsPromptly() async throws {
        let units = (0..<40).map { Self.bearsThenAClaw(20_000, paragraph: $0) }
        let index = KeywordSearch(units: units, updateInterval: .seconds(3600))
        let query = SearchQuery("bear claw")
        let clock = ContinuousClock()
        let whole = await clock.measure { _ = await updates(index, query) }
        let search = Task { await updates(index, query) }
        try await Task.sleep(for: whole / 10)
        search.cancel()
        let start = clock.now
        let received = await search.value
        let stopping = clock.now - start
        print(
            "search of 40 huge paragraphs: \(whole); stopped \(stopping) after cancelling,"
                + (received.isEmpty ? " mid-search" : " after it had finished"))
        #expect(stopping < whole / 2)
    }
}
