/// A stretch of a unit's text the Search sheet marks.
public struct Highlight: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A keyword occurrence.
        case match
        /// In a near match, a word where the query had a different one next to a matched word:
        /// "paw" in "bear paw" when the search was "bear claw".
        case differs
    }

    /// UTF-16 offsets into `SearchUnit.text`, so `NSRange(range)` addresses the same characters
    /// in AppKit. Since model text is ASCII, these are also character offsets.
    public let range: Range<Int>
    public let kind: Kind
}

/// How closely a unit's matched words sit together.
public enum ProximityTier: Int, Comparable, Hashable, Sendable {
    /// Spread over more than one sentence of the unit (a unit is at most a paragraph).
    case paragraph
    case sentence

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The score that orders units with equal coverage and tier: higher is better. Its scale has
/// no meaning outside one search.
public struct FineScore: Comparable, Hashable, Sendable {
    let value: Double

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}

/// How well a unit matches, compared in exactly this order (PLAN §9.2).
public struct Rank: Comparable, Hashable, Sendable {
    /// The number of distinct keywords matched.
    public let coverage: Int
    public let tier: ProximityTier
    public let fine: FineScore

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.coverage, lhs.tier, lhs.fine) < (rhs.coverage, rhs.tier, rhs.fine)
    }
}

/// One unit that matched.
public struct SearchHit: Hashable, Sendable {
    public let unit: SearchUnit
    public let rank: Rank
    /// In text order, not overlapping.
    public let highlights: [Highlight]
}

/// A scene's hits, best first. The Search sheet shows the first with "+N more in this scene".
public struct SceneHits: Hashable, Sendable {
    /// Never empty.
    public let hits: [SearchHit]

    public var best: SearchHit { hits[0] }
    public var moreCount: Int { hits.count - 1 }
    public var version: SearchVersion { best.unit.version }
    public var scene: SceneID { best.unit.scene }
}

/// Whether the hits contain every keyword.
public enum MatchQuality: Hashable, Sendable {
    case exact
    /// No unit contains every keyword, so these are the best partial matches: "No exact matches ·
    /// Near matches".
    case near
}

public enum SearchProgress: Hashable, Sendable {
    case searching(unitsSearched: Int, of: Int)
    case complete
}

/// What a search has found so far: each update replaces the previous one.
public struct SearchUpdate: Hashable, Sendable {
    /// Ordered by each scene's best hit.
    public let scenes: [SceneHits]
    public let quality: MatchQuality
    public let progress: SearchProgress

    public var hitCount: Int { scenes.reduce(0) { $0 + $1.hits.count } }
}
