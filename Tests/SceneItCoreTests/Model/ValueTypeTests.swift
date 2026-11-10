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

@Suite struct ZoomStepTests {
    private func percents(_ zooms: [Zoom]) -> [Int] {
        zooms.map { Int((Double($0) * 100).rounded()) }
    }

    @Test func theStepsCoverTheRangeInOrder() {
        #expect(percents(Zoom.steps) == [50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300])
        #expect(Zoom.steps.first == Zoom(clamping: ZoomBounds.range.lowerBound))
        #expect(Zoom.steps.last == Zoom(clamping: ZoomBounds.range.upperBound))
        #expect(Zoom.steps.contains(.standard))
        #expect(Zoom.steps == Zoom.steps.sorted())
    }

    @Test func zoomingInAndOutWalksEveryStep() {
        var zoom = Zoom(clamping: 0.5)
        var walked = [zoom]
        while zoom.canZoomIn {
            zoom = zoom.zoomedIn
            walked.append(zoom)
        }
        #expect(walked == Zoom.steps)
        while zoom.canZoomOut {
            zoom = zoom.zoomedOut
            walked.append(zoom)
        }
        #expect(Array(walked.reversed().prefix(Zoom.steps.count)) == Zoom.steps)
    }

    @Test func theEndsSaturate() {
        let most = Zoom(clamping: 3)
        let least = Zoom(clamping: 0.5)
        #expect(most.zoomedIn == most)
        #expect(!most.canZoomIn)
        #expect(least.zoomedOut == least)
        #expect(!least.canZoomOut)
    }

    @Test func aZoomBetweenStepsGoesToTheNeighbouringSteps() {
        let pinched = Zoom(clamping: 1.37)
        #expect(pinched.zoomedIn == Zoom(clamping: 1.5))
        #expect(pinched.zoomedOut == Zoom(clamping: 1.25))
        let nearlyOneTen = Zoom(clamping: 1.102)
        #expect(nearlyOneTen.zoomedIn == Zoom(clamping: 1.25), "within the tolerance of 110% counts as 110%")
        #expect(nearlyOneTen.zoomedOut == Zoom(clamping: 1))
        #expect(Zoom(clamping: 2.999).zoomedIn == Zoom(clamping: 3))
    }

    @Test func aZoomWithinTheToleranceOfAStepIsAtThatStepOnly() {
        let nearly = Zoom(clamping: 1.503)
        #expect(Zoom.steps.filter(nearly.isAt) == [Zoom(clamping: 1.5)])
        #expect(Zoom.steps.filter(Zoom(clamping: 1.37).isAt).isEmpty, "between steps")
        #expect(Zoom.steps.filter(Zoom.standard.isAt) == [.standard])
    }

    @Test func nanAndInfinityZoomFromTheirClampedValues() {
        #expect(Zoom(clamping: .nan).zoomedIn == Zoom(clamping: 1.1))
        #expect(Zoom(clamping: .infinity).zoomedOut == Zoom(clamping: 2.5))
        #expect(Zoom(clamping: -.infinity).zoomedIn == Zoom(clamping: 0.67))
    }
}
