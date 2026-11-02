import Foundation
import Testing

@testable import SceneItCore

/// A multiple of a week since the epoch, so every tier's buckets start exactly here.
private let aligned = Date(timeIntervalSince1970: 2_000 * 604_800)
private let now = aligned + .days(100)

private func ago(_ interval: Interval) -> Date { now - interval }

/// The tier and bucket a past snapshot falls in, computed independently of the code under test.
private func bucket(of date: Date) -> String {
    let age = now.timeIntervalSince(date)
    let seconds = date.timeIntervalSince1970
    if age < 86_400 { return "fine \(Int((seconds / 600).rounded(.down)))" }
    if age < 30 * 86_400 { return "day \(Int((seconds / 86_400).rounded(.down)))" }
    return "week \(Int((seconds / 604_800).rounded(.down)))"
}

@Suite struct RetentionTests {
    @Test func nothingToPruneInAnEmptyOrSingletonSet() {
        #expect(SnapshotSchedule.toDelete([], now: now).isEmpty)
        for age in [Interval.zero, .minutes(5), .days(2), .days(400)] {
            #expect(SnapshotSchedule.toDelete([ago(age)], now: now).isEmpty)
        }
    }

    @Test func theFineTierKeepsTheOldestInEachTenMinuteWindow() {
        let window = now - .hours(3)
        #expect(
            window.timeIntervalSince1970.truncatingRemainder(dividingBy: 600) == 0, "precondition: aligned")
        let first = window
        let last = window + .seconds(599)
        let next = window + .minutes(10)
        let newest = ago(.zero)
        #expect(SnapshotSchedule.toDelete([first, last, next, newest], now: now) == [last])
    }

    @Test func theDayTierStartsAtExactlyTwentyFourHours() {
        let dayTier = ago(.hours(24))
        let fineTier = ago(.hours(24) - .seconds(1))
        #expect(
            bucket(of: dayTier).hasPrefix("day") && bucket(of: fineTier).hasPrefix("fine"), "precondition")
        let newest = ago(.zero)
        #expect(SnapshotSchedule.toDelete([dayTier, fineTier, newest], now: now).isEmpty)

        let earlier = ago(.hours(30))
        let later = ago(.hours(24) + .seconds(1))
        #expect(bucket(of: earlier) == bucket(of: later), "precondition: same UTC day")
        #expect(SnapshotSchedule.toDelete([earlier, later, newest], now: now) == [later])
    }

    @Test func theDayTierKeepsTheOldestInEachUTCDay() {
        let midnight = aligned + .days(90)
        let snapshots: Set = [
            midnight - .seconds(1), midnight, midnight + .hours(12), midnight + .days(1) - .seconds(1),
        ]
        let newest = ago(.zero)
        #expect(
            SnapshotSchedule.toDelete(snapshots.union([newest]), now: now)
                == [midnight + .hours(12), midnight + .days(1) - .seconds(1)])
    }

    @Test func theWeekTierStartsAtExactlyThirtyDays() {
        let weekTier = ago(.days(30))
        let dayTier = ago(.days(30) - .seconds(1))
        #expect(
            bucket(of: weekTier).hasPrefix("week") && bucket(of: dayTier).hasPrefix("day"), "precondition")
        let newest = ago(.zero)
        #expect(SnapshotSchedule.toDelete([weekTier, dayTier, newest], now: now).isEmpty)
    }

    @Test func theWeekTierKeepsTheOldestInEachWeek() {
        let weekStart = aligned
        let snapshots: Set = [
            weekStart - .seconds(1), weekStart, weekStart + .days(3), weekStart + .days(7) - .seconds(1),
        ]
        let newest = ago(.zero)
        #expect(
            SnapshotSchedule.toDelete(snapshots.union([newest]), now: now)
                == [weekStart + .days(3), weekStart + .days(7) - .seconds(1)])
    }

    @Test func theNewestIsKeptEvenWhenItSharesABucket() {
        let older = ago(.days(50))
        let newest = older + .hours(1)
        #expect(bucket(of: older) == bucket(of: newest), "precondition: same week")
        #expect(SnapshotSchedule.toDelete([older, newest], now: now).isEmpty)
    }

    @Test func futureSnapshotsAreNeverDeleted() {
        let future: Set = [now + .seconds(1), now + .seconds(2), now + .minutes(1), now + .days(400)]
        #expect(SnapshotSchedule.toDelete(future, now: now).isEmpty)
        // The newest snapshot at or before now is kept too, though a future one is newer.
        let older = ago(.minutes(3))
        let newestPast = ago(.minutes(2))
        #expect(bucket(of: older) == bucket(of: newestPast), "precondition: same window")
        #expect(SnapshotSchedule.toDelete(future.union([older, newestPast]), now: now).isEmpty)
        let oldest = ago(.minutes(4))
        #expect(SnapshotSchedule.toDelete(future.union([oldest, older, newestPast]), now: now) == [older])
    }

    @Test func randomSetsSatisfyEveryRetentionProperty() {
        var generator = SplitMix64(seed: 9)
        for _ in 0..<300 {
            let count = Int.random(in: 0...120, using: &generator)
            let spans: [TimeInterval] = [3_600, 86_400 * 3, 86_400 * 60, 86_400 * 400]
            let span = spans.randomElement(using: &generator)!
            let snapshots = Set(
                (0..<count).map { _ in
                    now.addingTimeInterval(-Double.random(in: -span / 10...span, using: &generator).rounded())
                })
            let deleted = SnapshotSchedule.toDelete(snapshots, now: now)
            let kept = snapshots.subtracting(deleted)

            #expect(deleted.isSubset(of: snapshots))
            if let newest = snapshots.max() { #expect(kept.contains(newest)) }
            if let newestPast = snapshots.filter({ $0 <= now }).max() { #expect(kept.contains(newestPast)) }
            #expect(deleted.allSatisfy { $0 <= now }, "never a future snapshot")
            #expect(SnapshotSchedule.toDelete(kept, now: now).isEmpty, "stable under re-application")

            let byBucket = Dictionary(grouping: snapshots.filter { $0 <= now }, by: bucket(of:))
            let newestPast = snapshots.filter { $0 <= now }.max()
            for (name, members) in byBucket {
                let survivors = Set(members).intersection(kept)
                #expect(survivors.contains(members.min()!), "\(name) keeps its oldest")
                #expect(
                    survivors.subtracting([newestPast].compactMap(\.self)).count <= 1, "\(name) keeps one")
            }
        }
    }
}

@Suite struct CadenceTests {
    @Test func dueWithNoSnapshots() {
        #expect(SnapshotSchedule.decision(snapshots: [], now: now) == .due)
    }

    @Test func dueAtExactlyTenMinutes() {
        #expect(SnapshotSchedule.decision(snapshots: [ago(.minutes(10))], now: now) == .due)
        #expect(SnapshotSchedule.decision(snapshots: [ago(.minutes(10) - .seconds(1))], now: now) == .notDue)
        #expect(SnapshotSchedule.decision(snapshots: [ago(.zero)], now: now) == .notDue)
    }

    @Test func onlyTheNewestCounts() {
        #expect(SnapshotSchedule.decision(snapshots: [ago(.days(3)), ago(.minutes(1))], now: now) == .notDue)
        #expect(SnapshotSchedule.decision(snapshots: [ago(.days(3)), ago(.minutes(11))], now: now) == .due)
    }

    @Test func futureSnapshotsDoNotPostponeSnapshots() {
        #expect(SnapshotSchedule.decision(snapshots: [now + .days(30)], now: now) == .due)
        #expect(SnapshotSchedule.decision(snapshots: [now + .days(30), ago(.hours(1))], now: now) == .due)
        #expect(
            SnapshotSchedule.decision(snapshots: [now + .days(30), ago(.minutes(1))], now: now) == .notDue)
    }
}

@Suite struct SnapshotNameTests {
    @Test func namesAreUTCSecondsAndRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_793_543_405.75)
        let name = try #require(SnapshotName(date: date))
        #expect(name.fileName == "book-20261101T143005Z.json")
        #expect(name.date == Date(timeIntervalSince1970: 1_793_543_405))
        #expect(SnapshotName(fileName: name.fileName) == name)
    }

    @Test(arguments: [
        "book-20261102T143005Z.json.bak", "book-20261102T143005Z.JSON", "Book-20261102T143005Z.json",
        "book-20261102T143005.json", "book-2026-11-02T14:30:05Z.json", "book-20261302T143005Z.json",
        "book-20260231T143005Z.json", "book-20261102T246005Z.json", "book-20261102T143060Z.json",
        ".book-20261102T143005Z.json.0000.tmp", "book-٢٠٢٦1102T143005Z.json", "book-id", "package-path",
        "notes.txt", "",
    ])
    func onlyExactNamesParse(_ name: String) {
        #expect(SnapshotName(fileName: name) == nil)
    }

    @Test func datesOutsideFourDigitYearsHaveNoName() {
        #expect(SnapshotName(date: Date(timeIntervalSince1970: 300_000_000_000)) == nil)
        #expect(SnapshotName(date: .distantPast) == nil)
    }
}
