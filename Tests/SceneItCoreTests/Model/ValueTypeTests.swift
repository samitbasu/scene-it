import Foundation
import Testing

@testable import SceneItCore

@Suite struct TimestampTests {
    @Test(arguments: [
        "2026-10-31T20:54:00-07:00",
        "1970-01-01T00:00:00+00:00",
        "1969-12-31T23:59:59+00:00",
        "2000-02-29T12:00:00+05:45",
        "1582-10-10T00:00:00+00:00",
        "0001-01-01T00:00:00+00:00",
        "9999-12-31T23:59:59-23:59",
    ])
    func formatsWhatItParses(text: String) throws {
        #expect(try timestamp(text).description == text)
    }

    @Test(arguments: [
        "2026-10-31T20:54:00-07:00",
        "1969-07-20T20:17:40+00:00",
        "2000-02-29T12:00:00+05:45",
        "1900-03-01T00:00:00+01:00",
    ])
    func agreesWithFoundationOnTheInstant(text: String) throws {
        let foundation = try Date.ISO8601FormatStyle().parse(text)
        #expect(try timestamp(text).date == foundation)
    }

    @Test func keepsTheOffsetOfTheTimeZoneItWasMadeIn() throws {
        let instant = try Date.ISO8601FormatStyle().parse("2026-11-01T03:54:00Z")
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(Timestamp(instant, in: zone).description == "2026-10-31T20:54:00-07:00")
    }

    @Test func truncatesToWholeSeconds() throws {
        let instant = Date(timeIntervalSince1970: 1.999)
        let stamp = Timestamp(instant, in: TimeZone(secondsFromGMT: 0)!)
        #expect(stamp.description == "1970-01-01T00:00:01+00:00")
        #expect(try timestamp(stamp.description) == stamp)
    }

    @Test func truncatesNegativeInstantsTowardThePast() {
        let stamp = Timestamp(Date(timeIntervalSince1970: -0.5), in: TimeZone(secondsFromGMT: 0)!)
        #expect(stamp.description == "1969-12-31T23:59:59+00:00")
    }

    @Test func clampsToWhatTheFormatCanSpell() {
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(
            Timestamp(Date(timeIntervalSince1970: 1e15), in: utc).description == "9999-12-31T23:59:59+00:00")
        #expect(
            Timestamp(Date(timeIntervalSince1970: -1e12), in: utc).description == "0000-01-01T00:00:00+00:00")
    }

    @Test func sameInstantWithAnotherOffsetIsADifferentTimestamp() throws {
        let west = try timestamp("2026-10-31T20:54:00-07:00")
        let utc = try timestamp("2026-11-01T03:54:00+00:00")
        #expect(west.date == utc.date)
        #expect(west != utc)
    }
}

@Suite struct IdentifierTests {
    @Test func idsCompareByBytesNotCanonicalEquivalence() {
        let composed = CommentID(rawValue: "caf\u{E9}")
        let decomposed = CommentID(rawValue: "cafe\u{301}")
        #expect(composed.rawValue == decomposed.rawValue, "precondition: String == is canonical")
        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
        #expect(decomposed < composed)
    }
}

@Suite struct BoundedScalarTests {
    @Test func zoomClampsToItsRange() {
        #expect(Double(Zoom(clamping: 9)) == 3)
        #expect(Double(Zoom(clamping: 0.1)) == 0.5)
        #expect(Double(Zoom(clamping: 1.5)) == 1.5)
        #expect(Double(Zoom(clamping: -.infinity)) == 0.5)
    }

    @Test func nanBecomesTheFallback() {
        #expect(Double(Zoom(clamping: .nan)) == 1)
        #expect(Float(SpeechRate(clamping: .nan)) == 0.5)
    }

    @Test func exactlyRejectsOutOfRangeAndNaN() {
        #expect(Zoom(exactly: 3.01) == nil)
        #expect(Zoom(exactly: .nan) == nil)
        #expect(SpeechRate(exactly: 1.5) == nil)
        #expect(SpeechRate(exactly: 1) != nil)
    }

    @Test func orderingFollowsTheValue() {
        #expect(Zoom(clamping: 0.5) < Zoom(clamping: 2))
        #expect(SpeechRate(clamping: 0.2) < SpeechRate(clamping: 0.3))
    }
}

@Suite struct IDGeneratorTests {
    private static let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private func generator(milliseconds: @escaping () -> Double, seed: UInt64 = 1) -> IDGenerator<SplitMix64>
    {
        IDGenerator(
            now: { Date(timeIntervalSince1970: milliseconds() / 1000) }, random: SplitMix64(seed: seed))
    }

    @Test func idsAreTwentySixCrockfordCharacters() {
        var ids = generator(milliseconds: { 1_761_969_240_000 })
        for _ in 0..<100 {
            let id = ids.sceneID().rawValue
            #expect(id.count == 26)
            #expect(id.allSatisfy(Self.crockford.contains))
        }
    }

    @Test func theFirstTenCharactersEncodeTheMillisecond() {
        var zero = generator(milliseconds: { 0 })
        #expect(zero.commentID().rawValue.hasPrefix("0000000000"))
        var maximum = generator(milliseconds: { Double((1 << 48) - 1) })
        #expect(maximum.commentID().rawValue.hasPrefix("7ZZZZZZZZZ"))
    }

    @Test func idsSortByCreationTime() {
        var now = 1_761_969_240_000.0
        var ids = generator(milliseconds: {
            now += 1
            return now
        })
        let made = (0..<200).map { _ in ids.sceneID() }
        #expect(made == made.sorted())
    }

    @Test func aSeededGeneratorIsReproducible() {
        var first = generator(milliseconds: { 1_761_969_240_000 }, seed: 42)
        var second = generator(milliseconds: { 1_761_969_240_000 }, seed: 42)
        #expect((0..<10).map { _ in first.sceneID() } == (0..<10).map { _ in second.sceneID() })
    }

    @Test func idsWithinOneMillisecondDiffer() {
        var ids = generator(milliseconds: { 1_761_969_240_000 })
        let made = (0..<1000).map { _ in ids.commentID() }
        #expect(Set(made).count == made.count)
    }
}
