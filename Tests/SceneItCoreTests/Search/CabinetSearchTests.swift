import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// The File Cabinet scope's pure parts (#34, PLAN §9.1–9.2): the date range, the copy picker, the
/// copies' own tag units, searching several indexes as one, and grouping by copy.
@Suite struct CabinetSearchTests {
    static func day(_ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: 2026, month: month, day: day)!
    }

    static func copy(_ number: Int, _ filed: CalendarDay, tags: [String] = []) -> FiledCopy {
        FiledCopy(number: FiledCopyNumber(number)!, filed: filed, tags: tags)
    }

    /// Mockup 12's five copies, in the index's order (by number).
    static let index = ArchiveIndex(copies: [
        copy(1, day(3, 16), tags: ["draft 1", "complete"]),
        copy(2, day(7, 14), tags: ["draft 2"]),
        copy(3, day(9, 17), tags: ["contest"]),
        copy(4, day(10, 13), tags: ["draft 3"]),
        copy(5, day(10, 30), tags: ["beta readers", "draft 3"]),
    ])

    static func numbers(_ copies: [FiledCopy]) -> [Int] {
        copies.map(\.number.value)
    }

    // MARK: The date range

    @Test func eitherEndOfTheRangeMayBeOpen() {
        let sep17 = Self.day(9, 17)
        #expect(FiledDates().isOpen)
        #expect(FiledDates().contains(sep17))
        #expect(FiledDates(from: sep17).contains(sep17), "the ends are in the range")
        #expect(FiledDates(to: sep17).contains(sep17))
        #expect(!FiledDates(from: Self.day(9, 18)).contains(sep17))
        #expect(!FiledDates(to: Self.day(9, 16)).contains(sep17))
        #expect(FiledDates(from: Self.day(9, 1), to: Self.day(9, 30)).contains(sep17))
        #expect(!FiledDates(from: Self.day(10, 1), to: Self.day(9, 1)).contains(sep17), "backwards: nothing")
        #expect(!FiledDates(from: sep17).isOpen && !FiledDates(to: sep17).isOpen)
    }

    @Test func theRangeNarrowsThePickerNewestFirst() {
        #expect(Self.numbers(CabinetChoice().pickable(in: Self.index)) == [5, 4, 3, 2, 1])
        let autumn = CabinetChoice(dates: FiledDates(from: Self.day(9, 1)))
        #expect(Self.numbers(autumn.pickable(in: Self.index)) == [5, 4, 3])
        let summer = CabinetChoice(dates: FiledDates(from: Self.day(7, 1), to: Self.day(9, 30)))
        #expect(Self.numbers(summer.pickable(in: Self.index)) == [3, 2])
        #expect(CabinetChoice(dates: FiledDates(to: Self.day(1, 1))).pickable(in: Self.index).isEmpty)
    }

    /// The File Cabinet sheet's own filter and the search's range are one filter: the same dates
    /// show the same copies in both.
    @Test func theRangeIsTheFileCabinetsOwnDateFilter() {
        let ranges = [
            FiledDates(), FiledDates(from: Self.day(9, 17)), FiledDates(to: Self.day(10, 13)),
            FiledDates(from: Self.day(7, 1), to: Self.day(10, 13)),
        ]
        for dates in ranges {
            #expect(
                CabinetChoice(dates: dates).pickable(in: Self.index)
                    == FileCabinet.cards(of: Self.index, CabinetFilter(from: dates.from, to: dates.to)))
        }
    }

    // MARK: The copy picker

    @Test func allCopiesOrTheOnePicked() {
        #expect(Self.numbers(CabinetChoice().searched(in: Self.index)) == [5, 4, 3, 2, 1])
        let fourth = CabinetChoice(copy: FiledCopyNumber(4))
        #expect(Self.numbers(fourth.searched(in: Self.index)) == [4])
        let inRange = CabinetChoice(dates: FiledDates(from: Self.day(9, 1)), copy: FiledCopyNumber(4))
        #expect(Self.numbers(inRange.searched(in: Self.index)) == [4])
        #expect(inRange.fitted(to: Self.index) == inRange, "a picked copy in the range stays picked")
    }

    @Test func aPickedCopyTheRangeLeavesOutIsForgotten() {
        let picked = CabinetChoice(dates: FiledDates(from: Self.day(10, 1)), copy: FiledCopyNumber(2))
        #expect(picked.searched(in: Self.index).isEmpty, "never a copy the picker can't show")
        let fitted = picked.fitted(to: Self.index)
        #expect(fitted == CabinetChoice(dates: FiledDates(from: Self.day(10, 1))))
        #expect(Self.numbers(fitted.searched(in: Self.index)) == [5, 4])

        let gone = CabinetChoice(copy: FiledCopyNumber(9))
        #expect(gone.fitted(to: Self.index) == CabinetChoice(), "a copy the index no longer has")
    }

    // MARK: Units

    @Test func aCopysOwnTagsAreOneUnit() throws {
        let unit = try #require(SearchUnit.tags(of: Self.index.copies[4]))
        #expect(unit.version == .filed(FiledCopyNumber(5)!))
        #expect(unit.source == .copyTags)
        #expect(unit.text == "beta readers\ndraft 3")
        #expect(unit.isTagSet && unit.scene == nil && unit.field == nil)
        #expect(SearchUnit.tags(of: Self.copy(6, Self.day(11, 1))) == nil, "no tags, no unit")
    }

    @Test func copyTagsAreSearchedOnlyWithSearchTags() async throws {
        let units = Self.index.copies.compactMap(SearchUnit.tags(of:))
        #expect(try await finalUpdate(units, "draft").scenes.isEmpty)
        let found = try await finalUpdate(units, "draft", .searchTags)
        #expect(Set(found.scenes.map(\.version)) == Set([1, 2, 4, 5].map { .filed(FiledCopyNumber($0)!) }))
        #expect(found.scenes.allSatisfy { $0.scene == nil })
        let phrase = try await finalUpdate(units, "\"readers draft\"", .searchTags)
        #expect(phrase.scenes.isEmpty, "a phrase can't run from one tag into the next")
    }

    @Test func aFiledCopysUnitsAreItsBooks() {
        let book = PerformanceTests.novel(words: 6_000)
        let number = FiledCopyNumber(3)!
        let units = SearchUnit.units(of: book, version: .filed(number))
        let working = SearchUnit.units(of: book, version: .working)
        #expect(!units.isEmpty)
        #expect(units.allSatisfy { $0.version == .filed(number) })
        #expect(units.map(\.source) == working.map(\.source))
        #expect(units.map(\.text) == working.map(\.text))
    }

    // MARK: Several indexes as one

    /// Searching the copies' indexes together ranks as one index over all their units would.
    @Test func severalIndexesRankAsOne() async throws {
        let copies = (1...3).map { number in
            [
                SearchUnit(
                    version: .filed(FiledCopyNumber(number)!), scene: SceneID(rawValue: "s1"),
                    sceneTitle: "The letter", placement: .story(number: 1), field: .title, text: "The letter"),
                SearchUnit(
                    version: .filed(FiledCopyNumber(number)!), scene: SceneID(rawValue: "s2"),
                    sceneTitle: "Dawn", placement: .story(number: 2), field: .body(paragraph: 0),
                    text: number == 2
                        ? "She burned the letter and the bear's claw." : "A letter came at dawn."),
            ]
        }
        let query = SearchQuery("letter claw")
        var combined: [SearchUpdate] = []
        for await update in CombinedKeywordSearch(copies.map { KeywordSearch(units: $0) }).search(query) {
            combined.append(update)
        }
        var single: [SearchUpdate] = []
        for await update in KeywordSearch(units: copies.flatMap(\.self)).search(query) {
            single.append(update)
        }
        let together = try #require(combined.last)
        #expect(together.progress == .complete)
        #expect(together.scenes == single.last?.scenes)
        #expect(together.quality == .exact)
        #expect(together.scenes.map(\.version) == [.filed(FiledCopyNumber(2)!)])
    }

    @Test func equalRanksKeepTheIndexesOrder() async throws {
        let copies = [5, 4, 3].map { number in
            [
                SearchUnit(
                    version: .filed(FiledCopyNumber(number)!), scene: SceneID(rawValue: "s1"),
                    sceneTitle: "One",
                    placement: .story(number: 1), field: .body(paragraph: 0), text: "The letter.")
            ]
        }
        var last: SearchUpdate?
        for await update in CombinedKeywordSearch(copies.map { KeywordSearch(units: $0) }).search(
            SearchQuery("letter"))
        {
            last = update
        }
        #expect(last?.scenes.map(\.version) == [5, 4, 3].map { .filed(FiledCopyNumber($0)!) })
        #expect(Set(last?.scenes.map(\.best.rank) ?? []).count == 1, "precondition: equal ranks")
    }

    @Test func noIndexesFindNothing() async {
        var updates: [SearchUpdate] = []
        for await update in CombinedKeywordSearch([]).search(SearchQuery("letter")) { updates.append(update) }
        #expect(updates.map(\.progress) == [.complete])
        #expect(updates.last?.scenes.isEmpty == true)
    }

    // MARK: Grouping by copy

    private static func hits(_ version: Int?, scene: String?) -> SceneHits {
        let unit =
            if let scene {
                SearchUnit(
                    version: version.map { .filed(FiledCopyNumber($0)!) } ?? .working,
                    scene: SceneID(rawValue: scene), sceneTitle: scene, placement: .story(number: 1),
                    field: .body(paragraph: 0), text: "a letter")
            } else {
                SearchUnit(version: .filed(FiledCopyNumber(version!)!), source: .copyTags, text: "letter")
            }
        return SceneHits(hits: [
            SearchHit(
                unit: unit, rank: Rank(coverage: 1, tier: .sentence, fine: FineScore(value: 0)),
                highlights: [Highlight(range: 2..<8, kind: .match)])
        ])
    }

    @Test func resultsAreGroupedByCopyInTheGivenOrder() {
        let scenes = [
            Self.hits(4, scene: "a"), Self.hits(5, scene: nil), Self.hits(4, scene: "b"),
            Self.hits(5, scene: "a"), Self.hits(nil, scene: "a"),
        ]
        let groups = VersionHits.grouped(scenes, by: [5, 3, 4].map { .filed(FiledCopyNumber($0)!) })
        #expect(
            groups.map(\.version) == [5, 4].map { .filed(FiledCopyNumber($0)!) }, "no group without hits")
        #expect(groups[0].scenes == [scenes[1], scenes[3]], "each group in the engine's order")
        #expect(groups[1].scenes == [scenes[0], scenes[2]])
        #expect(!groups.flatMap(\.scenes).contains(scenes[4]), "a version not asked for is left out")
    }

    @Test func theSummaryCountsScenesCopiesAndCopyTags() {
        let scenes = [
            Self.hits(4, scene: "a"), Self.hits(5, scene: nil), Self.hits(4, scene: "b"),
            Self.hits(5, scene: "a"), Self.hits(3, scene: nil),
        ]
        let counts = CabinetCounts(scenes)
        #expect(
            [counts.matches, counts.scenes, counts.copies, counts.taggedCopies] as [Int] == [3, 3, 2, 2],
            "copy tags are neither matches in scenes nor scenes")
        #expect(
            SearchWording.cabinetSummary(counts)
                == "3 matches in 3 scenes across 2 filed copies · tags match on 2 copies")
        let tagsOnly = CabinetCounts([Self.hits(3, scene: nil)])
        #expect(SearchWording.cabinetSummary(tagsOnly) == "Tags match on 1 copy")
        let one = CabinetCounts([Self.hits(3, scene: "a")])
        #expect(SearchWording.cabinetSummary(one) == "1 match in 1 scene across 1 filed copy")
    }
}

/// The File Cabinet search at scale (PLAN §9.2's target: about 500 ms across 50 filed copies once
/// they're loaded). The gate runs 50 small copies in a debug build and asserts only a generous
/// ceiling; `SCENEIT_CABINET_BENCHMARK_WORDS=120000 swift test -c release --filter
/// CabinetSearchPerformance` runs 50 copies of a 120,000-word novel and prints the times.
@Suite struct CabinetSearchPerformanceTests {
    static let copies = 50
    static let words =
        ProcessInfo.processInfo.environment["SCENEIT_CABINET_BENCHMARK_WORDS"].flatMap { Int($0) } ?? 6_000
    static let queries = ["harbor gulls", "\"the island\"", "Mara watched the letter", "cafe zebra"]

    @Test func fiftyCopiesAreSearchedQuickly() async {
        let clock = ContinuousClock()
        let book = PerformanceTests.novel(words: Self.words)
        var indexes: [KeywordSearch] = []
        let footprint = Self.footprint()
        let indexing = clock.measure {
            for number in 1...Self.copies {
                indexes.append(
                    KeywordSearch(
                        units: SearchUnit.units(of: book, version: .filed(FiledCopyNumber(number)!))))
            }
        }
        let held = (Self.footprint() - footprint) / 1_000_000
        let units = indexes.reduce(0) { $0 + $1.units.count }
        #expect(units == Self.copies * SearchUnit.units(of: book, version: .working).count)
        var times: [String] = []
        var total = Duration.zero
        for text in Self.queries {
            let query = SearchQuery(text)
            var run = SearchRun(indexes: indexes, query: query)
            var updates = 0
            var first: Duration?
            let start = clock.now
            var last: SearchUpdate
            repeat {
                last = run.advance()!
                updates += 1
                if first == nil, !last.scenes.isEmpty { first = clock.now - start }
            } while last.progress != .complete
            let elapsed = clock.now - start
            total += elapsed
            #expect(Set(last.scenes.map(\.version)).count == Self.copies || last.scenes.isEmpty)
            times.append(
                "\(text): \(elapsed.formatted(.units(allowed: [.milliseconds]))) "
                    + "(first results after \((first ?? elapsed).formatted(.units(allowed: [.milliseconds]))), "
                    + "\(updates) updates, \(last.hitCount) hits)")
        }
        print(
            "cabinet search, \(Self.copies) copies of \(Self.words) words (\(units) units): indexing \(indexing), about \(held) MB held; "
                + times.joined(separator: "; "))
        #expect(total < .seconds(Self.words > 6_000 ? 60 : 20))
    }

    /// The process's memory footprint, as Activity Monitor's Memory column shows it, in bytes.
    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
