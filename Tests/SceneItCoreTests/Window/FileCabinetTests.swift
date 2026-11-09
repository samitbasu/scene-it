import Foundation
import Testing

@testable import SceneItCore

/// The File Cabinet's cards and filters (PLAN §7.4), and the click policy it shares with the
/// Scenes sheet (ADR 0043, 0046).
struct FileCabinetTests {
    static func day(_ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: 2026, month: month, day: day)!
    }

    static func copy(_ number: Int, _ filed: CalendarDay, tags: [String] = [], note: String = "") -> FiledCopy
    {
        FiledCopy(number: FiledCopyNumber(number)!, filed: filed, tags: tags, note: note)
    }

    /// Mockup 12's five copies, filed in number order.
    static let index = ArchiveIndex(copies: [
        copy(1, day(3, 16), tags: ["draft 1", "complete"], note: "First complete draft."),
        copy(2, day(7, 14), tags: ["draft 2"], note: "Before cutting the brother subplot."),
        copy(
            3, day(9, 17), tags: ["contest", "first 3 chapters"],
            note: "Version submitted to the regional fiction contest."),
        copy(4, day(10, 13), tags: ["draft 3"], note: "After the big restructure: Fog moved before Debts."),
        copy(
            5, day(10, 30), tags: ["beta readers", "Draft 3"],
            note: "Sent to the four beta readers. Ending still soft."),
    ])

    static func numbers(_ filter: CabinetFilter) -> [Int] {
        FileCabinet.cards(of: index, filter).map(\.number.value)
    }

    @Test func cardsAreNewestFirstByDateThenNumber() {
        #expect(Self.numbers(CabinetFilter()) == [5, 4, 3, 2, 1])
        var index = Self.index
        index.copies.append(Self.copy(6, Self.day(3, 16)))
        #expect(FileCabinet.cards(of: index, CabinetFilter()).map(\.number.value) == [5, 4, 3, 2, 6, 1])
    }

    @Test func everyWordMustAppearInATagOrTheNoteIgnoringCase() {
        #expect(Self.numbers(CabinetFilter(words: "draft")) == [5, 4, 2, 1])
        #expect(Self.numbers(CabinetFilter(words: "DRAFT before")) == [4, 2])
        #expect(Self.numbers(CabinetFilter(words: "beta soft")) == [5])
        #expect(Self.numbers(CabinetFilter(words: "lighthouse")) == [])
        #expect(Self.numbers(CabinetFilter(words: "   ")) == [5, 4, 3, 2, 1], "spaces filter nothing")
    }

    @Test func theDateRangeIncludesBothEndsAndEitherMayBeOpen() {
        #expect(Self.numbers(CabinetFilter(from: Self.day(9, 17))) == [5, 4, 3])
        #expect(Self.numbers(CabinetFilter(to: Self.day(9, 17))) == [3, 2, 1])
        #expect(Self.numbers(CabinetFilter(from: Self.day(7, 1), to: Self.day(10, 13))) == [4, 3, 2])
        #expect(Self.numbers(CabinetFilter(from: Self.day(11, 1))) == [])
        #expect(
            Self.numbers(CabinetFilter(from: Self.day(10, 1), to: Self.day(9, 1))) == [], "backwards: none")
    }

    @Test func chosenTagsMustAllBeOnACopyInAnyCase() {
        var filter = CabinetFilter()
        filter.toggle("draft 3")
        #expect(Self.numbers(filter) == [5, 4])
        #expect(filter.isChosen("DRAFT 3"))
        filter.toggle("beta readers")
        #expect(Self.numbers(filter) == [5])
        filter.toggle("Draft 3")
        #expect(filter.tags == ["beta readers"], "toggled off in any case")
        #expect(Self.numbers(filter) == [5])
    }

    @Test func filtersCombine() {
        var filter = CabinetFilter(words: "ending", from: Self.day(10, 1))
        #expect(Self.numbers(filter) == [5])
        filter.toggle("draft 2")
        #expect(Self.numbers(filter) == [])
        #expect(!filter.isEmpty && CabinetFilter().isEmpty)
    }

    @Test func theChipsAreEveryTagOnceSortedIgnoringCaseInTheNewestSpelling() {
        #expect(
            FileCabinet.tags(of: Self.index) == [
                "beta readers", "complete", "contest", "draft 1", "draft 2", "Draft 3", "first 3 chapters",
            ])
        #expect(FileCabinet.tags(of: ArchiveIndex()) == [])
    }

    @Test func theSpanIsTheOldestAndNewestDay() {
        #expect(FileCabinet.span(of: Self.index) == Self.day(3, 16)...Self.day(10, 30))
        #expect(FileCabinet.span(of: ArchiveIndex()) == nil)
    }

    @Test func theAgeCountsDays() {
        let today = Self.day(11, 1)
        #expect(FiledAge(of: today, today: today) == .today)
        #expect(FiledAge(of: Self.day(10, 31), today: today) == .yesterday)
        #expect(FiledAge(of: Self.day(10, 30), today: today) == .ago(.days(2)))
        #expect(FiledAge(of: Self.day(10, 13), today: today) == .ago(.weeks(2)))
        #expect(FiledAge(of: Self.day(9, 17), today: today) == .ago(.months(1)))
        #expect(FiledAge(of: Self.day(3, 16), today: today) == .ago(.months(7)))
        #expect(FiledAge(of: CalendarDay(year: 2024, month: 11, day: 1)!, today: today) == .ago(.years(2)))
        #expect(FiledAge(of: Self.day(11, 2), today: today) == .future)
        let springForward = CalendarDay(year: 2026, month: 3, day: 9)!
        #expect(
            FiledAge(of: CalendarDay(year: 2026, month: 3, day: 7)!, today: springForward) == .ago(.days(2)),
            "a day across a clock change is still a day")
    }

    @Test func theCardsWording() {
        let english = Locale(identifier: "en_US")
        let counts = FiledCopyCounts(scenes: 24, words: 1409, comments: 3)
        #expect(
            FileCabinetWording.details(.ago(.days(2)), counts, locale: english)
                == "2 days ago \u{00B7} 24 scenes \u{00B7} 1,409 words \u{00B7} 3 comments")
        #expect(
            FileCabinetWording.details(
                .today, FiledCopyCounts(scenes: 1, words: 1, comments: 1), locale: english)
                == "today \u{00B7} 1 scene \u{00B7} 1 word \u{00B7} 1 comment")
        #expect(FileCabinetWording.details(.yesterday, nil, locale: english) == "yesterday")
        #expect(
            FileCabinetWording.subtitle(copies: 5)
                == "5 filed copies \u{00B7} double-click one to open it read-only")
        #expect(FileCabinetWording.subtitle(copies: 0) == "0 filed copies")
    }

    // MARK: Clicks (ADR 0043, 0046)

    @Test func aSingleClickSelectsAndADoubleClickOnTheSameItemOpens() {
        var clicks = CardClicks<Int>()
        #expect(clicks.take(.single, on: 1) == .select(1))
        #expect(clicks.take(.double, on: 1) == .open(1))
        #expect(clicks.last == 1, "opening keeps the click")
    }

    @Test func aDoubleClickWhoseFirstClickWentElsewhereOnlySelects() {
        var clicks = CardClicks<Int>()
        #expect(clicks.take(.double, on: 2) == .select(2), "no first click on it")
        #expect(clicks.take(.single, on: 1) == .select(1))
        #expect(clicks.take(.double, on: 2) == .select(2), "the first click landed on 1")
        clicks.forget()
        #expect(clicks.last == nil)
        #expect(clicks.take(.double, on: 2) == .select(2), "forgotten: a first click again")
    }
}
