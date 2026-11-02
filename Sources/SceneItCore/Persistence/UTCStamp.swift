import Foundation

/// A time to the second in UTC, written `20261101T143005Z` (ISO 8601's basic format). It
/// sorts by date and is safe in a file name. Snapshot and conflict names in a package use it;
/// diagnostics files keep their own stamps, with fractions of a second.
enum UTCStamp {
    /// Fractions of a second are dropped.
    static func string(for date: Date) -> String {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: second(of: date))
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// `nil` unless `stamp` is exactly what `string(for:)` writes for some date.
    static func date(from stamp: some StringProtocol) -> Date? {
        guard
            let match = String(stamp).wholeMatch(
                of: /(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z/.asciiOnlyDigits()),
            let date = calendar.date(
                from: DateComponents(
                    year: Int(match.1), month: Int(match.2), day: Int(match.3), hour: Int(match.4),
                    minute: Int(match.5), second: Int(match.6))),
            string(for: date) == stamp
        else { return nil }
        return date
    }

    static func second(of date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}
