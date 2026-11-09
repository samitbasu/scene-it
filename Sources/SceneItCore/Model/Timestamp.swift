import Foundation

/// A UTC offset in whole minutes, within ISO 8601's ±23:59.
public struct UTCOffset: Hashable, Sendable {
    public static let maximumMinutes = 23 * 60 + 59
    public static let zero = UTCOffset(uncheckedMinutes: 0)
    public let minutes: Int

    public init?(minutes: Int) {
        guard abs(minutes) <= Self.maximumMinutes else { return nil }
        self.minutes = minutes
    }

    /// The zone's offset at `date`, truncated to whole minutes.
    public init(_ timeZone: TimeZone, at date: Date) {
        let minutes = timeZone.secondsFromGMT(for: date) / 60
        self.init(uncheckedMinutes: min(max(minutes, -Self.maximumMinutes), Self.maximumMinutes))
    }

    private init(uncheckedMinutes: Int) {
        minutes = uncheckedMinutes
    }
}

/// An instant with whole-second precision, plus the UTC offset it's written with.
///
/// `book.md` writes times as `2026-10-31T20:54:00-07:00`. Keeping the offset makes the text
/// independent of the machine's time zone, and dropping sub-second precision makes
/// write → read an identity. Equality compares the offset too, because it's part of what's
/// written.
public struct Timestamp: Hashable, Sendable, CustomStringConvertible {
    public let secondsSince1970: Int64
    public let offset: UTCOffset

    /// `date`, truncated to the second and expressed in `timeZone`'s offset at that date.
    /// Clamped to the years 0000–9999, which is what the format can spell.
    public init(_ date: Date, in timeZone: TimeZone) {
        let offset = UTCOffset(timeZone, at: date)
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down).clampedToInt64)
        let offsetSeconds = Int64(offset.minutes * 60)
        let local = min(max(seconds + offsetSeconds, LocalDateTime.earliest), LocalDateTime.latest)
        self.init(secondsSince1970: local - offsetSeconds, offset: offset)
    }

    init(secondsSince1970: Int64, offset: UTCOffset) {
        self.secondsSince1970 = secondsSince1970
        self.offset = offset
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(secondsSince1970))
    }

    public var description: String {
        let sign = offset.minutes < 0 ? "-" : "+"
        let magnitude = abs(offset.minutes)
        return localDescription + sign + zeroPadded(magnitude / 60, width: 2) + ":"
            + zeroPadded(magnitude % 60, width: 2)
    }

    /// The date and time on the clock where it was taken, without the offset:
    /// `2026-11-03T10:15:00`.
    var localDescription: String {
        LocalDateTime(secondsSince1970: secondsSince1970 + Int64(offset.minutes * 60)).description
    }

    /// Reads `description`'s form, and also `Z` for `+00:00` (book format §2.2), which
    /// `description` never writes.
    public init?(_ text: String) {
        let bytes = Array(text.utf8)
        if bytes.count == 20, bytes[19] == UInt8(ascii: "Z"), let local = LocalDateTime(bytes[0..<19]) {
            self.init(secondsSince1970: local.secondsSince1970, offset: .zero)
            return
        }
        guard bytes.count == 25, let local = LocalDateTime(bytes[0..<19]) else { return nil }
        let sign: Int
        switch bytes[19] {
        case UInt8(ascii: "+"): sign = 1
        case UInt8(ascii: "-"): sign = -1
        default: return nil
        }
        guard bytes[22] == UInt8(ascii: ":"),
            let hours = digits(bytes[20..<22]), hours < 24,
            let minutes = digits(bytes[23..<25]), minutes < 60,
            let offset = UTCOffset(minutes: sign * (hours * 60 + minutes))
        else { return nil }
        self.init(secondsSince1970: local.secondsSince1970 - Int64(offset.minutes * 60), offset: offset)
    }
}

/// A date with no time or zone, written `2026-10-31`: the day a copy was filed, as the writer
/// gave it (PLAN §7.1, book format §8). Years 0000–9999, like `Timestamp`.
public struct CalendarDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// `nil` for a day the proleptic Gregorian calendar doesn't have, or a year outside 0000–9999.
    public init?(year: Int, month: Int, day: Int) {
        guard (0...9999).contains(year), (1...12).contains(month),
            (1...LocalDateTime.daysIn(month: month, year: year)).contains(day)
        else { return nil }
        self.init(LocalDateTime(year: year, month: month, day: day, hour: 0, minute: 0, second: 0))
    }

    /// The day `date` falls on in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        let timestamp = Timestamp(date, in: timeZone)
        self.init(
            LocalDateTime(secondsSince1970: timestamp.secondsSince1970 + Int64(timestamp.offset.minutes * 60))
        )
    }

    /// Reads exactly `description`'s form, `YYYY-MM-DD`.
    public init?(_ text: some StringProtocol) {
        guard let local = LocalDateTime(ArraySlice(Array(text.utf8) + Array("T00:00:00".utf8))) else {
            return nil
        }
        self.init(local)
    }

    private init(_ local: LocalDateTime) {
        year = local.year
        month = local.month
        day = local.day
    }

    public var description: String {
        zeroPadded(year, width: 4) + "-" + zeroPadded(month, width: 2) + "-" + zeroPadded(day, width: 2)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Noon of this day in `timeZone`: a date picker shows it as this day, whatever the
    /// daylight-saving shifts around it.
    public func noon(in timeZone: TimeZone) -> Date {
        let local = LocalDateTime(year: year, month: month, day: day, hour: 12, minute: 0, second: 0)
        let asIfUTC = Date(timeIntervalSince1970: TimeInterval(local.secondsSince1970))
        return asIfUTC - TimeInterval(timeZone.secondsFromGMT(for: asIfUTC))
    }
}

/// A proleptic Gregorian wall-clock time. The day arithmetic is Howard Hinnant's
/// `days_from_civil`/`civil_from_days`, which avoids `Calendar`'s Julian switch in 1582.
struct LocalDateTime: Equatable, CustomStringConvertible {
    static let earliest = LocalDateTime(year: 0, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        .secondsSince1970
    static let latest = LocalDateTime(year: 9999, month: 12, day: 31, hour: 23, minute: 59, second: 59)
        .secondsSince1970

    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int

    init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    init(secondsSince1970 seconds: Int64) {
        let (days, secondOfDay) = seconds.floorDivided(by: 86_400)
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        self.init(
            year: Int(yearOfEra + era * 400 + (month <= 2 ? 1 : 0)),
            month: Int(month),
            day: Int(dayOfYear - (153 * shiftedMonth + 2) / 5 + 1),
            hour: Int(secondOfDay / 3600),
            minute: Int(secondOfDay % 3600 / 60),
            second: Int(secondOfDay % 60))
    }

    /// Parses exactly `YYYY-MM-DDTHH:MM:SS`.
    init?(_ bytes: ArraySlice<UInt8>) {
        let start = bytes.startIndex
        let separators: [(Int, Character)] = [(4, "-"), (7, "-"), (10, "T"), (13, ":"), (16, ":")]
        guard bytes.count == 19,
            separators.allSatisfy({ bytes[start + $0.0] == $0.1.asciiValue }),
            let year = digits(bytes[start..<start + 4]),
            let month = digits(bytes[start + 5..<start + 7]), (1...12).contains(month),
            let day = digits(bytes[start + 8..<start + 10]),
            (1...Self.daysIn(month: month, year: year)).contains(day),
            let hour = digits(bytes[start + 11..<start + 13]), hour < 24,
            let minute = digits(bytes[start + 14..<start + 16]), minute < 60,
            let second = digits(bytes[start + 17..<start + 19]), second < 60
        else { return nil }
        self.init(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    var secondsSince1970: Int64 {
        let shiftedYear = Int64(month <= 2 ? year - 1 : year)
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let shiftedMonth = Int64((month + 9) % 12)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return days * 86_400 + Int64(hour * 3600 + minute * 60 + second)
    }

    var description: String {
        let date = [zeroPadded(year, width: 4), zeroPadded(month, width: 2), zeroPadded(day, width: 2)]
            .joined(separator: "-")
        let time = [hour, minute, second].map { zeroPadded($0, width: 2) }.joined(separator: ":")
        return date + "T" + time
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

/// `value` must be non-negative.
private func zeroPadded(_ value: Int, width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}

private func digits(_ bytes: ArraySlice<UInt8>) -> Int? {
    var value = 0
    for byte in bytes {
        guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
        value = value * 10 + Int(byte - UInt8(ascii: "0"))
    }
    return value
}

extension Int64 {
    fileprivate func floorDivided(by divisor: Int64) -> (quotient: Int64, remainder: Int64) {
        let remainder = self % divisor
        return remainder < 0 ? (self / divisor - 1, remainder + divisor) : (self / divisor, remainder)
    }
}

extension Double {
    fileprivate var clampedToInt64: Double {
        isNaN ? 0 : Swift.min(Swift.max(self, -1e17), 1e17)
    }
}
