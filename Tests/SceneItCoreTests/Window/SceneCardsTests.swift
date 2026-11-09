import Foundation
import SceneItTestSupport
import Synchronization
import Testing

@testable import SceneItCore

/// The Scenes sheet's pure parts (PLAN §7.2, #28): a card's first sentence, the filter, how long
/// ago a scene changed and how a card says it, the header's totals, and the ticker that keeps
/// the ages current.
@Suite(.timeLimit(.minutes(1)))
struct SceneCardsTests {
    // MARK: First sentence

    @Test func theExcerptIsTheFirstSentenceOfTheFirstParagraphWithText() {
        let body: [Paragraph] = [
            [], [Run("   ")],
            [Run("The ferry left at "), Run("dawn", styles: [.italic]), Run(". Mara watched.")],
            [Run("Second paragraph.")],
        ]
        #expect(SceneExcerpt.of(body) == "The ferry left at dawn.")
    }

    @Test func theExcerptFollowsSearchsSentenceRule() {
        #expect(SceneExcerpt.of([[Run("\"Go!\" she said. Then left.")]]) == "\"Go!\"")
        #expect(SceneExcerpt.of([[Run("It cost 3.5 coins, e.g. less. More.")]]) == "It cost 3.5 coins, e.g.")
        #expect(SceneExcerpt.of([[Run("Is it you?) Yes.")]]) == "Is it you?)")
        #expect(SceneExcerpt.of([[Run("No ending at all")]]) == "No ending at all")
        #expect(SceneExcerpt.of([[Run("  Leading spaces. Trimmed.")]]) == "Leading spaces.")
        #expect(SceneExcerpt.of([]) == "")
        #expect(SceneExcerpt.of([[], [Run(" ")]]) == "")
    }

    @Test func aLongSentenceIsCutToOneHundredTwentyCharactersWithAnEllipsis() throws {
        let exactly = String(repeating: "a", count: SceneExcerpt.limit)
        #expect(SceneExcerpt.of([[Run(exactly)]]) == exactly, "120 characters fit")
        let long = String(repeating: "word ", count: 40) + "end."
        let cut = SceneExcerpt.of([[Run(long)]])
        #expect(cut.count <= SceneExcerpt.limit)
        #expect(cut.hasSuffix(SceneExcerpt.ellipsis))
        #expect(!cut.dropLast().hasSuffix(" "), "no space before the ellipsis")
        #expect(long.hasPrefix(String(cut.dropLast())))
        let unbroken = String(repeating: "b", count: 200)
        #expect(SceneExcerpt.of([[Run(unbroken)]]).count == SceneExcerpt.limit)
    }

    @Test func firstSentenceEndAgreesWithTheTokensSentences() {
        let samples = [
            "Mr. Smith left. Then he came back!", "No end", "One.\nTwo.", "Wait... what?\" Yes.",
            "3.5 is not an end. This is.", ".", "", "Hello?!) There.",
        ]
        for sample in samples {
            let units = Array(sample.utf16)
            let end = SearchText.firstSentenceEnd(units)
            let tokens = SearchText.tokens(units)
            let first = tokens.first?.sentence
            #expect(
                tokens.filter { $0.sentence == first }.allSatisfy { Int($0.end) <= end },
                "\(sample): the first sentence's words are inside it")
            #expect(
                tokens.filter { $0.sentence != first }.allSatisfy { Int($0.start) >= end },
                "\(sample): the other sentences' words are after it")
        }
    }

    // MARK: Filter

    private static let ferry = BookScene(
        id: SceneID(rawValue: "ferry"), modified: Timestamp(Date(timeIntervalSince1970: 0), in: .gmt),
        title: "The Ferry", tags: ["Mara", "set piece"],
        body: [[Run("She watched the harbor lights.")], [Run("The engine coughed.")]])

    @Test func theFilterMatchesTitleTextAndTagsIgnoringCase() {
        for typed in ["ferry", "FERRY", "harbor", "Engine", "mara", "set piece", "piece", "lights the"] {
            #expect(SceneFilter(typed).matches(Self.ferry), "\(typed)")
        }
        for typed in ["boat", "ferry boat", "notes"] {
            #expect(!SceneFilter(typed).matches(Self.ferry), "\(typed)")
        }
    }

    @Test func aHashWordMatchesTagsOnly() {
        #expect(SceneFilter("#mara").matches(Self.ferry))
        #expect(SceneFilter("#set").matches(Self.ferry))
        #expect(!SceneFilter("#ferry").matches(Self.ferry), "the title isn't a tag")
        #expect(!SceneFilter("#harbor").matches(Self.ferry), "nor is the text")
        #expect(SceneFilter("#").isEmpty, "a lone # is no word")
    }

    @Test func anEmptyFilterMatchesEverything() {
        #expect(SceneFilter("").isEmpty && SceneFilter("  \t ").isEmpty)
        #expect(
            SceneFilter(" ").matches(
                BookScene(id: SceneID(rawValue: "x"), modified: Self.ferry.modified, title: "")))
    }

    @Test func notesAreNotSearched() {
        var scene = Self.ferry
        scene.notes = [[Run("Decide about the lighthouse.")]]
        #expect(!SceneFilter("lighthouse").matches(scene))
    }

    // MARK: Relative age

    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func age(_ interval: Interval) -> RelativeAge {
        RelativeAge(of: Self.now - interval, at: Self.now)
    }

    @Test func agesAreBucketedIntoTheLargestUnitThatFits() {
        let cases: [(Interval, RelativeAge)] = [
            (.zero, .justNow), (.seconds(59), .justNow), (.minutes(1), .minutes(1)),
            (.minutes(59), .minutes(59)),
            (.hours(1), .hours(1)), (.hours(6), .hours(6)), (.hours(23) + .minutes(59), .hours(23)),
            (.days(1), .yesterday), (.days(2) - .seconds(1), .yesterday), (.days(2), .days(2)),
            (.days(6), .days(6)), (.days(7), .weeks(1)), (.days(13), .weeks(1)), (.days(14), .weeks(2)),
            (.days(29), .weeks(4)), (.days(30), .months(1)), (.days(364), .months(12)),
            (.days(365), .years(1)), (.days(800), .years(2)),
        ]
        for (interval, expected) in cases {
            #expect(age(interval) == expected, "\(interval)")
        }
    }

    @Test func aChangeInTheFutureIsJustNow() {
        #expect(RelativeAge(of: Self.now + .days(3), at: Self.now) == .justNow)
    }

    @Test func aCardSaysItsAgeInWords() {
        let english = Locale(identifier: "en_US")
        let cases: [(RelativeAge, String)] = [
            (.justNow, "just now"), (.minutes(1), "1 minute ago"), (.minutes(5), "5 minutes ago"),
            (.hours(6), "6 hours ago"), (.yesterday, "yesterday"), (.days(2), "2 days ago"),
            (.weeks(1), "1 week ago"), (.weeks(2), "2 weeks ago"), (.months(1), "1 month ago"),
            (.months(2), "2 months ago"), (.years(3), "3 years ago"),
        ]
        for (age, words) in cases {
            #expect(ScenesWording.modified(age, locale: english) == words)
        }
    }

    // MARK: Totals

    @Test func theTotalsCountScenesAndWords() {
        #expect(
            ScenesWording.totals(scenes: 24, words: WordCount(words: 1409))
                == "24 scenes \u{00B7} 1,409 words")
        #expect(ScenesWording.totals(scenes: 1, words: WordCount(words: 1)) == "1 scene \u{00B7} 1 word")
        #expect(ScenesWording.totals(scenes: 0, words: .zero) == "0 scenes \u{00B7} 0 words")
    }

    // MARK: Ticker

    /// The wall time a test sets.
    private final class WallTime: Sendable {
        private let date = Mutex(Date(timeIntervalSince1970: 2_000_000_000))
        var now: Date { date.withLock { $0 } }
        func advance(_ interval: Interval) { date.withLock { $0 = $0 + interval } }
    }

    @MainActor
    @Test func theTickerReadsTheTimeOnceAMinuteWhileItRuns() async {
        let clock = ManualClock()
        let wall = WallTime()
        let ticker = MinuteTicker(clock: clock, wallTime: { wall.now })
        let start = wall.now
        #expect(ticker.now == start)
        let run = Task { await ticker.run() }
        await eventually { clock.sleeperCount == 1 }

        wall.advance(.seconds(59))
        clock.advance(by: .seconds(59))
        for _ in 0..<5 { await Task.yield() }
        #expect(clock.sleeperCount == 1 && ticker.now == start, "not before the minute is up")

        clock.advance(by: .seconds(1))
        await eventually { ticker.now == start + .seconds(59) && clock.sleeperCount == 1 }
        wall.advance(.hours(2))
        clock.advance(by: .minutes(1))
        await eventually { ticker.now == start + .seconds(59) + .hours(2) && clock.sleeperCount == 1 }

        run.cancel()
        _ = await run.value
        wall.advance(.minutes(5))
        clock.advance(by: .minutes(5))
        await Task.yield()
        #expect(ticker.now == start + .seconds(59) + .hours(2), "stopped with its task")
    }
}
