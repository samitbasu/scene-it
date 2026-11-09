import Foundation

/// The File Cabinet's filters (PLAN §7.4): words, a date range and tags. A filed copy shows when
/// every word typed appears, ignoring case, in one of its tags or its note; it was filed within
/// the range, either end of which may be open; and it has every tag chosen.
///
/// Searching the copies' text needs them read; that comes with the File Cabinet's search (#34).
public struct CabinetFilter: Hashable, Sendable {
    public var words = ""
    public var from: CalendarDay?
    public var to: CalendarDay?
    /// As the cabinet spells them, compared ignoring case (`SceneTag.key`).
    public private(set) var tags: [String] = []

    public init(words: String = "", from: CalendarDay? = nil, to: CalendarDay? = nil, tags: [String] = []) {
        self.words = words
        self.from = from
        self.to = to
        self.tags = tags
    }

    /// Nothing to filter by: every copy shows.
    public var isEmpty: Bool {
        typedWords.isEmpty && from == nil && to == nil && tags.isEmpty
    }

    public var hasDateRange: Bool {
        from != nil || to != nil
    }

    public func matches(_ copy: FiledCopy) -> Bool {
        let tags = copy.tags.map(SceneTag.key)
        let note = copy.note.lowercased()
        return typedWords.allSatisfy { word in note.contains(word) || tags.contains { $0.contains(word) } }
            && from.map { copy.filed >= $0 } != false
            && to.map { copy.filed <= $0 } != false
            && self.tags.allSatisfy { tags.contains(SceneTag.key($0)) }
    }

    public func isChosen(_ tag: String) -> Bool {
        SceneTag.contains(tags, tag)
    }

    /// A tag chip clicked: chosen if it wasn't, and not if it was.
    public mutating func toggle(_ tag: String) {
        if isChosen(tag) {
            tags.removeAll { SceneTag.key($0) == SceneTag.key(tag) }
        } else {
            tags.append(tag)
        }
    }

    /// Model text is ASCII (ADR 0028), so lowercasing is exact.
    private var typedWords: [String] {
        words.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    }
}

/// What the File Cabinet shows of an archive (PLAN §7.4).
public enum FileCabinet {
    /// The copies `filter` shows, newest first: by the date they were filed, then by number.
    public static func cards(of index: ArchiveIndex, _ filter: CabinetFilter) -> [FiledCopy] {
        index.copies.filter(filter.matches).sorted { ($0.filed, $0.number) > ($1.filed, $1.number) }
    }

    /// Every tag the copies have, each once, in the spelling of the newest copy that has it,
    /// sorted ignoring case.
    public static func tags(of index: ArchiveIndex) -> [String] {
        var seen: [String: String] = [:]
        for copy in cards(of: index, CabinetFilter()) {
            for tag in copy.tags where seen[SceneTag.key(tag)] == nil { seen[SceneTag.key(tag)] = tag }
        }
        return seen.values.sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
    }

    /// The days the copies were filed on, oldest and newest; `nil` with no copies.
    public static func span(of index: ArchiveIndex) -> ClosedRange<CalendarDay>? {
        guard let first = index.copies.map(\.filed).min(), let last = index.copies.map(\.filed).max() else {
            return nil
        }
        return first...last
    }
}

/// How long ago a copy was filed, by its date, as its card says it (PLAN §7.4).
public enum FiledAge: Hashable, Sendable {
    case today
    case yesterday
    /// Two days or more: a whole number of the largest unit that fits, as a scene card counts.
    case ago(RelativeAge)
    /// A date after today (a clock set back, a date typed in the dialog).
    case future

    public init(of filed: CalendarDay, today: CalendarDay) {
        let days = Int(
            (today.noon(in: .gmt).timeIntervalSince(filed.noon(in: .gmt)) / 86_400).rounded())
        self =
            switch days {
            case ..<0: .future
            case 0: .today
            case 1: .yesterday
            case ..<7: .ago(.days(days))
            case ..<30: .ago(.weeks(days / 7))
            case ..<365: .ago(.months(days / 30))
            default: .ago(.years(days / 365))
            }
    }
}
