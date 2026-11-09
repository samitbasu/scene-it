import Foundation

/// How the Scenes sheet shows the story (PLAN §7.2), remembered between launches.
public enum ScenesView: String, CaseIterable, Hashable, Sendable {
    /// A card per scene: its words, when it changed, its first sentence and its tags.
    case cards
    /// A dense grid of numbers, titles and tags.
    case lightTable
}

/// A card's line of text from the scene (PLAN §7.2): the first sentence of its first paragraph
/// that has any text, by search's sentence rule (`SearchText.tokens`), cut to `limit`
/// characters with an ellipsis.
public enum SceneExcerpt {
    public static let limit = 120
    public static let ellipsis = "\u{2026}"

    public static func of(_ body: [Paragraph]) -> String {
        guard
            let line = body.lazy.map({ $0.text.trimmingCharacters(in: .whitespaces) }).first(where: {
                !$0.isEmpty
            })
        else { return "" }
        let units = Array(line.utf16)
        let sentence = String(decoding: units[..<SearchText.firstSentenceEnd(units)], as: UTF16.self)
        return cut(sentence)
    }

    /// `text`, or its first characters and an ellipsis, `limit` characters in all.
    static func cut(_ text: String) -> String {
        guard text.count > limit else { return text }
        let kept = text.prefix(limit - ellipsis.count)
        return String(kept.reversed().drop(while: \.isWhitespace).reversed()) + ellipsis
    }
}

/// The Scenes sheet's filter field (PLAN §7.2): every word typed must appear, ignoring case, in
/// the scene's title, its text or one of its tags. A word written `#word` must appear in a tag.
/// Model text is ASCII (ADR 0028), so lowercasing is exact.
public struct SceneFilter: Hashable, Sendable {
    private let words: [Word]

    private struct Word: Hashable, Sendable {
        let text: String
        let place: Place
    }

    private enum Place: Hashable, Sendable {
        case anywhere, tags
    }

    public init(_ typed: String) {
        words = typed.split(whereSeparator: \.isWhitespace).compactMap { word in
            let lowered = word.lowercased()
            guard lowered.hasPrefix("#") else { return Word(text: lowered, place: .anywhere) }
            let tag = String(lowered.dropFirst())
            return tag.isEmpty ? nil : Word(text: tag, place: .tags)
        }
    }

    /// Nothing to filter by: every scene shows.
    public var isEmpty: Bool {
        words.isEmpty
    }

    public func matches(_ scene: BookScene) -> Bool {
        guard !isEmpty else { return true }
        let tags = scene.tags.map { $0.lowercased() }
        let title = scene.title.text.lowercased()
        let text = scene.body.map(\.text).joined(separator: "\n").lowercased()
        return words.allSatisfy { word in
            let inTags = tags.contains { $0.contains(word.text) }
            switch word.place {
            case .tags: return inTags
            case .anywhere: return inTags || title.contains(word.text) || text.contains(word.text)
            }
        }
    }
}

/// How long ago a scene changed, as a card says it (PLAN §7.2): a whole number of the largest
/// unit that fits. A change in the future (a clock set back, a hand-edited file) is just now.
public enum RelativeAge: Hashable, Sendable {
    case justNow
    case minutes(Int)
    case hours(Int)
    /// Between one and two days ago.
    case yesterday
    case days(Int)
    case weeks(Int)
    case months(Int)
    case years(Int)

    public init(of modified: Date, at now: Date) {
        let age = Interval(clamping: .seconds(now.timeIntervalSince(modified)))
        let seconds = Int(age.duration.components.seconds)
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        self =
            switch age {
            case ..<Interval.minutes(1): .justNow
            case ..<Interval.hours(1): .minutes(minutes)
            case ..<Interval.days(1): .hours(hours)
            case ..<Interval.days(2): .yesterday
            case ..<Interval.days(7): .days(days)
            case ..<Interval.days(30): .weeks(days / 7)
            case ..<Interval.days(365): .months(days / 30)
            default: .years(days / 365)
            }
    }
}
