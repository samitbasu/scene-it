import Foundation

/// A non-negative span of time (ADR 0010). Swift's `Duration` is signed, so every span our
/// APIs accept is an `Interval`, which clamps negative values to zero once, on construction.
public struct Interval: Hashable, Comparable, Sendable {
    public let duration: Duration

    public init(clamping duration: Duration) {
        self.duration = max(duration, .zero)
    }

    public static let zero = Interval(clamping: .zero)

    public static func seconds(_ count: Int) -> Interval { Interval(clamping: .seconds(count)) }
    public static func minutes(_ count: Int) -> Interval { .seconds(saturatingProduct(count, 60)) }
    public static func hours(_ count: Int) -> Interval { .seconds(saturatingProduct(count, 3600)) }
    public static func days(_ count: Int) -> Interval { .seconds(saturatingProduct(count, 86_400)) }

    public static func < (lhs: Interval, rhs: Interval) -> Bool { lhs.duration < rhs.duration }

    public static func + (lhs: Interval, rhs: Interval) -> Interval {
        Interval(clamping: lhs.duration + rhs.duration)
    }

    /// Saturates at zero.
    public static func - (lhs: Interval, rhs: Interval) -> Interval {
        Interval(clamping: lhs.duration - rhs.duration)
    }

    /// Seconds as Foundation's `TimeInterval`, for `Date` arithmetic.
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    private static func saturatingProduct(_ count: Int, _ factor: Int) -> Int {
        let (product, overflow) = count.multipliedReportingOverflow(by: factor)
        guard overflow else { return product }
        return count < 0 ? Int.min : Int.max
    }
}

extension Duration {
    public init(_ interval: Interval) {
        self = interval.duration
    }
}

extension Date {
    public static func - (date: Date, interval: Interval) -> Date {
        date.addingTimeInterval(-interval.timeInterval)
    }

    public static func + (date: Date, interval: Interval) -> Date {
        date.addingTimeInterval(interval.timeInterval)
    }
}
