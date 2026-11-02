import Foundation
import Testing

@testable import SceneItCore

/// A multiple of a week since the epoch, so every tier's buckets start exactly here.
private let aligned = Date(timeIntervalSince1970: 2_000 * 604_800)
private let now = aligned + .days(100)

private func ago(_ interval: Interval) -> Date { now - interval }

/// The tier and bucket a past snapshot falls in at `now`, computed independently of the code
/// under test: the finest tier whose bucket around the snapshot ended less than its limit ago.
private func bucket(of date: Date) -> String {
    let (tier, index) = RetentionModel.bucket(
        of: Int64(date.timeIntervalSince1970), now: Int64(now.timeIntervalSince1970))
    return "\(["fine", "day", "week"][tier]) \(index)"
}

/// The retention guarantees in whole seconds, as a model to check `SnapshotSchedule` against.
private enum RetentionModel {
    static let tiers: [(spacing: Int64, until: Int64?)] = [
        (600, 86_400), (86_400, 30 * 86_400), (604_800, nil),
    ]

    static func floorDivision(_ a: Int64, _ b: Int64) -> Int64 {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    static func bucket(of second: Int64, now: Int64) -> (tier: Int, index: Int64) {
        for (tier, (spacing, until)) in tiers.enumerated() {
            let index = floorDivision(second, spacing)
            guard let until else { return (tier, index) }
            if now - (index + 1) * spacing < until { return (tier, index) }
        }
        return (tiers.count - 1, floorDivision(second, tiers[tiers.count - 1].spacing))
    }

    /// Snapshots written at the increasing seconds of `history`, pruned to `kept` by `now`.
    static func check(history: [Int64], kept: Set<Int64>, now: Int64, _ label: String) {
        if let newest = history.max() { #expect(kept.contains(newest), "\(label): newest") }
        var perBucket: [String: Int] = [:]
        for second in kept {
            let (tier, index) = bucket(of: second, now: now)
            perBucket["\(tier)/\(index)", default: 0] += 1
        }
        #expect(perBucket.values.filter { $0 > 1 }.count <= 1, "\(label): one per bucket, plus the newest")
        // The first snapshot of every week is kept, and of every day and window still in its tier.
        var first: [String: Int64] = [:]
        for second in history {
            for (tier, (spacing, until)) in tiers.enumerated() {
                let index = floorDivision(second, spacing)
                if let until, now - (index + 1) * spacing >= until { continue }
                first["\(tier)/\(index)"] = min(first["\(tier)/\(index)"] ?? second, second)
            }
        }
        for (name, second) in first {
            #expect(kept.contains(second), "\(label): bucket \(name) lost its first snapshot")
        }
    }
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

    /// A window stays in the fine tier until its end is 24 h old.
    @Test func theDayTierTakesAWindowWhenItsEndIsTwentyFourHoursOld() {
        let endedADayAgo = (ago(.hours(24) + .minutes(10)), ago(.hours(24) + .minutes(5)))
        let startedADayAgo = (ago(.hours(24)), ago(.hours(24) - .minutes(5)))
        #expect(
            bucket(of: endedADayAgo.0).hasPrefix("day") && bucket(of: endedADayAgo.1).hasPrefix("day"),
            "precondition")
        #expect(
            bucket(of: startedADayAgo.0) == bucket(of: startedADayAgo.1)
                && bucket(of: startedADayAgo.0).hasPrefix("fine"), "precondition: one fine window")
        let newest = ago(.zero)
        #expect(
            SnapshotSchedule.toDelete(
                [endedADayAgo.0, endedADayAgo.1, startedADayAgo.0, startedADayAgo.1, newest], now: now)
                == [endedADayAgo.1, startedADayAgo.1])

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

    /// A day stays a day until its end is 30 days old, even when it began longer ago.
    @Test func aDayStraddlingThirtyDaysKeepsItsSnapshot() {
        let later = now + .days(1) + .hours(12)
        let straddling = later - .days(30) - .hours(6)
        let dayBefore = straddling - .days(1)
        let week = { (date: Date) in Int((date.timeIntervalSince1970 / 604_800).rounded(.down)) }
        #expect(week(straddling) == week(dayBefore), "precondition: one week")
        let dayStart = (straddling.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400
        #expect(
            later.timeIntervalSince1970 - (dayStart + 86_400) < 30 * 86_400
                && later.timeIntervalSince1970 - dayStart > 30 * 86_400,
            "precondition: its day ends within 30 days but began before")
        #expect(SnapshotSchedule.toDelete([dayBefore, straddling, later], now: later).isEmpty)

        let endedThirtyDaysAgo = (now - .days(31) + .hours(5), now - .days(31) + .hours(6))
        #expect(
            bucket(of: endedThirtyDaysAgo.0) == bucket(of: endedThirtyDaysAgo.1), "precondition: one week")
        #expect(bucket(of: endedThirtyDaysAgo.0).hasPrefix("week"), "precondition")
        #expect(
            SnapshotSchedule.toDelete([endedThirtyDaysAgo.0, endedThirtyDaysAgo.1, now], now: now)
                == [endedThirtyDaysAgo.1])
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

    /// Writes as the cadence allows, at random gaps from seconds to weeks, pruning after every
    /// save as the keeper does, and checks the model's guarantees after each step.
    @Test(arguments: [
        ("1970", Int64(0)), ("before 1970", Int64(-400 * 86_400)), ("leap day 2028", Int64(1_835_395_200)),
        ("2038", Int64(2_147_483_647 - 10 * 86_400)), ("2100", Int64(4_107_542_400 - 40 * 86_400)),
        ("9999", Int64(253_402_300_799 - 400 * 86_400)),
    ])
    func iteratedPruningKeepsTheGuaranteesInEveryEra(_ era: (String, Int64)) {
        for seed in UInt64(1)...4 {
            var generator = SplitMix64(seed: seed)
            var kept = Set<Int64>()
            var history: [Int64] = []
            var second = era.1
            while second < era.1 + 150 * 86_400 {
                let roll = UInt64.random(in: 0..<100, using: &generator)
                let gap: Int64 =
                    roll < 70
                    ? Int64.random(in: 0..<900, using: &generator)
                    : roll < 95
                        ? Int64.random(in: 0..<86_400, using: &generator)
                        : Int64.random(in: 0..<(20 * 86_400), using: &generator)
                second += gap
                let now = Date(timeIntervalSince1970: TimeInterval(second))
                let dates = Set(kept.map { Date(timeIntervalSince1970: TimeInterval($0)) })
                guard SnapshotSchedule.decision(snapshots: dates, now: now) == .due else { continue }
                kept.subtract(
                    SnapshotSchedule.toDelete(dates, now: now).map { Int64($0.timeIntervalSince1970) })
                kept.insert(second)
                history.append(second)
                RetentionModel.check(history: history, kept: kept, now: second, "\(era.0) #\(seed)")
            }
            #expect(history.count > 50, "precondition: \(era.0) #\(seed) wrote enough snapshots")
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
        ".book-20261102T143005Z.json.0000.tmp", "book-٢٠٢٦1102T143005Z.json", "book-id", "package.json",
        "notes.txt", "", "book-20270229T000000Z.json", "book-20261028T240000Z.json",
        "book-２０２６1028T000000Z.json", "book-20261028T000000Z.json\n", " book-20261028T000000Z.json",
        "book-20261028t000000Z.json", "book-+2026102T000000Z.json", "book-20261028T000000Z.json\u{0}",
        "book-2026\u{200B}1028T000000Z.json", "book-00001028T000000Z.json", "book-19691231T235959Z.json",
    ])
    func onlyExactNamesParse(_ name: String) {
        #expect(SnapshotName(fileName: name) == nil)
    }

    @Test(
        arguments: [
            (Int64(0), "book-19700101T000000Z.json"), (1_835_395_200 - 1, "book-20280228T235959Z.json"),
            (1_835_395_200, "book-20280229T000000Z.json"), (1_835_481_600, "book-20280301T000000Z.json"),
            (2_147_483_648, "book-20380119T031408Z.json"), (253_402_300_799, "book-99991231T235959Z.json"),
        ] as [(Int64, String)])
    func namesAcrossEras(_ example: (Int64, String)) throws {
        let name = try #require(SnapshotName(date: Date(timeIntervalSince1970: TimeInterval(example.0))))
        #expect(name.fileName == example.1)
        #expect(SnapshotName(fileName: example.1) == name)
    }

    @Test func datesOutsideTheYears1970To9999HaveNoName() {
        #expect(SnapshotName(date: Date(timeIntervalSince1970: 253_402_300_800)) == nil)
        #expect(SnapshotName(date: Date(timeIntervalSince1970: -1)) == nil)
        #expect(SnapshotName(date: .distantPast) == nil)
    }

    @Test func conflictNamesUseTheSameStamp() {
        let layout = PackageLayout(root: URL(filePath: "/Books/Novel.sceneit"))
        let date = Date(timeIntervalSince1970: 1_793_543_405.75)
        #expect(
            layout.conflict(at: date, attempt: 1).lastPathComponent == "book.json.conflict-20261101T143005Z")
        #expect(
            layout.conflict(at: date, attempt: 2).lastPathComponent == "book.json.conflict-20261101T143005Z-2"
        )
    }
}
