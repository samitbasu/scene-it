import Foundation

/// When to take a tiered snapshot and which ones to keep (ADR 0005). Pure: it sees only
/// the snapshots' dates and the current time.
///
/// Each tier keeps the oldest snapshot in each of its buckets. Buckets are aligned to the
/// Unix epoch in UTC (10-minute windows, UTC days, and weeks starting on a Thursday), so
/// every day is a union of 10-minute windows and every week a union of days. A snapshot
/// belongs to the finest tier that still holds the *end* of its bucket there, so a day that
/// is partly within the last 30 days is still a day, and keeps its first snapshot.
public enum SnapshotSchedule {
    struct Tier {
        /// How long after a bucket ends it leaves this tier; `nil` for the last tier.
        let until: Interval?
        let spacing: Interval
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
            let bucket = Bucket.of(date, now: now)
            oldestInBucket[bucket] = min(oldestInBucket[bucket] ?? date, date)
        }
        return past.subtracting(oldestInBucket.values).subtracting([newestPast])
    }

    private struct Bucket: Hashable {
        let tier: Int
        let index: Int64

        static func of(_ date: Date, now: Date) -> Bucket {
            let buckets = tiers.indices.map { tier in
                let spacing = tiers[tier].spacing.timeInterval
                return (
                    Bucket(tier: tier, index: Int64((date.timeIntervalSince1970 / spacing).rounded(.down))),
                    spacing
                )
            }
            let held = buckets.first { bucket, spacing in
                let end = Date(timeIntervalSince1970: TimeInterval(bucket.index + 1) * spacing)
                return tiers[bucket.tier].until.map { age(of: end, at: now) < $0 } ?? true
            }
            return (held ?? buckets[buckets.count - 1]).0
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

/// A snapshot's file name, `book-20261101T143005Z.md`: the `UTCStamp` of the second it was
/// taken. Pruning deletes only files whose names round-trip through this.
struct SnapshotName: Hashable {
    let fileName: String
    let date: Date

    /// `nil` for a date outside the years 1970…9999, which no working clock reads.
    init?(date: Date) {
        let second = UTCStamp.second(of: date)
        let stamp = UTCStamp.string(for: second)
        guard second.timeIntervalSince1970 >= 0, UTCStamp.date(from: stamp) == second else { return nil }
        fileName = "book-\(stamp).md"
        self.date = second
    }

    /// `nil` unless `fileName` is exactly a name that `init(date:)` produces.
    init?(fileName: String) {
        guard fileName.hasPrefix("book-"), fileName.hasSuffix(".md"),
            let date = UTCStamp.date(from: fileName.dropFirst("book-".count).dropLast(".md".count)),
            let canonical = SnapshotName(date: date), canonical.fileName == fileName
        else { return nil }
        self = canonical
    }
}
