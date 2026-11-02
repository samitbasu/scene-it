import Foundation

/// When to take a tiered snapshot and which ones to keep (ADR 0005). Pure: it sees only
/// the snapshots' dates and the current time.
///
/// Each tier keeps the oldest snapshot in each of its buckets. Buckets are aligned to the
/// Unix epoch in UTC (10-minute windows, UTC days, and weeks starting on a Thursday), so
/// every day is a union of 10-minute windows and every week a union of days: the snapshot a
/// coarser tier keeps is one that the finer tier kept too.
public enum SnapshotSchedule {
    struct Tier {
        /// The age a snapshot leaves this tier at; `nil` for the last tier.
        let until: Interval?
        let spacing: Interval

        func holds(_ age: Interval) -> Bool {
            until.map { age < $0 } ?? true
        }
    }

    static let tiers = [
        Tier(until: .hours(24), spacing: .minutes(10)),
        Tier(until: .days(30), spacing: .days(1)),
        Tier(until: nil, spacing: .days(7)),
    ]

    static var finestSpacing: Interval { tiers[0].spacing }

    /// Due when no snapshot is at or before `now`, or the newest such one is at least the
    /// finest tier's spacing old. Snapshots dated after `now` (the clock went back) are
    /// ignored, so they can't stop snapshots until the clock catches up.
    public static func decision(snapshots: some Sequence<Date>, now: Date) -> SnapshotDecision {
        guard let newest = snapshots.filter({ $0 <= now }).max() else { return .due }
        return age(of: newest, at: now) >= finestSpacing ? .due : .notDue
    }

    /// The snapshots to delete. Never the newest, never the newest at or before `now`, and
    /// never one dated after `now`.
    public static func toDelete(_ snapshots: Set<Date>, now: Date) -> Set<Date> {
        let past = snapshots.filter { $0 <= now }
        guard let newestPast = past.max() else { return [] }
        var oldestInBucket: [Bucket: Date] = [:]
        for date in past {
            let bucket = Bucket(date, age: age(of: date, at: now))
            oldestInBucket[bucket] = min(oldestInBucket[bucket] ?? date, date)
        }
        return past.subtracting(oldestInBucket.values).subtracting([newestPast])
    }

    private struct Bucket: Hashable {
        let tier: Int
        let index: Int64

        init(_ date: Date, age: Interval) {
            let tiers = SnapshotSchedule.tiers
            tier = tiers.firstIndex { $0.holds(age) } ?? tiers.count - 1
            let spacing = tiers[tier].spacing.timeInterval
            index = Int64((date.timeIntervalSince1970 / spacing).rounded(.down))
        }
    }

    private static func age(of date: Date, at now: Date) -> Interval {
        Interval(clamping: .seconds(now.timeIntervalSince(date)))
    }
}

public enum SnapshotDecision: Hashable, Sendable {
    case due
    case notDue
}

/// A snapshot's file name, `book-20261101T143005Z.json`: the UTC second it was taken, so
/// names sort by date. Pruning deletes only files whose names round-trip through this.
struct SnapshotName: Hashable {
    let fileName: String
    let date: Date

    /// `nil` for a date outside the years 1970…9999, which no working clock reads.
    init?(date: Date) {
        let second = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        let parts = Self.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: second)
        guard second.timeIntervalSince1970 >= 0, let year = parts.year, year <= 9999, let month = parts.month,
            let day = parts.day,
            let hour = parts.hour, let minute = parts.minute, let seconds = parts.second
        else { return nil }
        fileName = String(
            format: "book-%04d%02d%02dT%02d%02d%02dZ.json", year, month, day, hour, minute, seconds)
        self.date = second
    }

    /// `nil` unless `fileName` is exactly a name that `init(date:)` produces.
    init?(fileName: String) {
        guard
            let match = fileName.wholeMatch(
                of: /book-(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z\.json/.asciiOnlyDigits()),
            let date = Self.calendar.date(
                from: DateComponents(
                    year: Int(match.1), month: Int(match.2), day: Int(match.3), hour: Int(match.4),
                    minute: Int(match.5), second: Int(match.6))),
            let canonical = SnapshotName(date: date), canonical.fileName == fileName
        else { return nil }
        self = canonical
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}
