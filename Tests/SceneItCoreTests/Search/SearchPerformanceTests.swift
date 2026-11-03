import Foundation
import Testing

@testable import SceneItCore

/// A sanity check, not a benchmark (PLAN §9.2 targets about 100 ms for a 120,000-word working book
/// in a release build). A debug build is far slower, and other suites load the machine, so this
/// asserts only a generous ceiling and that the whole book costs about twice half of it.
@Suite struct SearchPerformanceTests {
    private struct Timing {
        let indexing: Duration
        let searching: Duration
    }

    /// The best of three, to shed scheduling noise.
    private func timing(words: Int) async -> Timing {
        let units = SearchUnit.units(of: PerformanceTests.novel(words: words), version: .working)
        let clock = ContinuousClock()
        var indexings: [Duration] = []
        var searchings: [Duration] = []
        for _ in 0..<3 {
            var index: KeywordSearch?
            indexings.append(clock.measure { index = KeywordSearch(units: units) })
            let start = clock.now
            for query in ["harbor gulls", "\"the island\"", "Mara watched the letter", "cafe zebra"] {
                _ = await updates(index!, SearchQuery(query))
            }
            searchings.append((clock.now - start) / 4)
        }
        return Timing(indexing: indexings.min()!, searching: searchings.min()!)
    }

    @Test func aLongNovelIsSearchedQuickly() async throws {
        let book = PerformanceTests.novel(words: 120_000)
        let words = book.scenes.flatMap(\.body).map(\.text).map { $0.split(separator: " ").count }.reduce(
            0, +)
        #expect(words >= 120_000, "precondition: a long novel")
        let found = try #require(
            await updates(
                KeywordSearch(units: SearchUnit.units(of: book, version: .working)),
                SearchQuery("harbor gulls")
            ).last)
        #expect(found.hitCount > 100, "precondition: the query matches throughout")

        let full = await timing(words: 120_000)
        let half = await timing(words: 60_000)
        print(
            "search, \(words) words: index \(full.indexing), query \(full.searching); half: index \(half.indexing), query \(half.searching)"
        )
        #expect(full.indexing + full.searching < .seconds(10))
        #expect(
            full.indexing < half.indexing * 3 + .milliseconds(50),
            "\(half.indexing) for half, \(full.indexing) for all")
        #expect(
            full.searching < half.searching * 3 + .milliseconds(50),
            "\(half.searching) for half, \(full.searching) for all")
    }

    /// A paragraph whose only window holding both keywords is the whole of it: `repeats` bears,
    /// then a claw. A window search that rescans the window as it shrinks is quadratic here.
    private static func bearsThenAClaw(_ repeats: Int, paragraph: Int = 0) -> SearchUnit {
        unit(String(repeating: "bear ", count: repeats) + "claw", field: .body(paragraph: paragraph))
    }

    @Test func aHugeParagraphIsSearchedInLinearTime() async throws {
        let query = SearchQuery("bear claw")
        let clock = ContinuousClock()
        func time(_ repeats: Int) async throws -> Duration {
            let index = KeywordSearch(units: [Self.bearsThenAClaw(repeats)])
            let last = try #require(await updates(index, query).last)
            #expect(hits(last).first?.rank.coverage == 2, "precondition: one window holds both keywords")
            var best = Duration.seconds(3600)
            for _ in 0..<3 {
                best = min(best, await clock.measure { _ = await updates(index, query) })
            }
            return best
        }
        let half = try await time(50_000)
        let full = try await time(100_000)
        print("search, one paragraph of 50,000 and 100,000 words: \(half), \(full)")
        #expect(full < half * 3 + .milliseconds(50), "\(half) for half, \(full) for all")
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
