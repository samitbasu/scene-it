import Foundation

/// One search in progress: the units searched so far and what they matched.
struct SearchRun {
    private let index: KeywordSearch
    private let keywords: [CompiledKeyword]
    private let includesTags: Bool
    private var cursor = 0
    private var unitsSearched = 0
    /// Per keyword, how many of the units searched contain it.
    private var unitsContaining: [Int]
    private var matches: [UnitMatch] = []

    init(index: KeywordSearch, query: SearchQuery) {
        self.index = index
        keywords = CompiledKeyword.distinct(query, in: index)
        includesTags = query.options.contains(.searchTags)
        unitsContaining = Array(repeating: 0, count: keywords.count)
        if keywords.isEmpty { cursor = index.units.count }
    }

    /// Searches the next batch of units and reports everything found so far.
    mutating func advance() -> SearchUpdate {
        let end = min(cursor + index.unitsPerUpdate, index.units.count)
        for unitIndex in cursor..<end {
            let unit = index.units[unitIndex]
            guard includesTags || unit.unit.field != .tags else { continue }
            unitsSearched += 1
            guard let match = UnitMatch(unit, at: unitIndex, keywords: keywords, forms: index.forms) else {
                continue
            }
            for (keyword, count) in match.occurrenceCounts.enumerated() where count > 0 {
                unitsContaining[keyword] += 1
            }
            matches.append(match)
        }
        cursor = end
        return update()
    }

    private func update() -> SearchUpdate {
        let quality: MatchQuality =
            matches.contains { $0.coverage == keywords.count } || matches.isEmpty ? .exact : .near
        let rarity = unitsContaining.map { RankingWeights.rarity(unitsContaining: $0, of: unitsSearched) }
        let shown = matches.filter { quality == .near || $0.coverage == keywords.count }
        let ranked: [(unitIndex: Int, hit: SearchHit)] = shown.map { match in
            (match.unitIndex, match.hit(index.units[match.unitIndex].unit, rarity: rarity, quality: quality))
        }
        let hits = ranked.sorted(by: Self.better).map(\.hit)
        let progress: SearchProgress =
            cursor == index.units.count
            ? .complete : .searching(unitsSearched: cursor, of: index.units.count)
        return SearchUpdate(scenes: Self.grouped(hits), quality: quality, progress: progress)
    }

    /// Higher rank first; equal ranks in book order.
    private static func better(
        _ lhs: (unitIndex: Int, hit: SearchHit), _ rhs: (unitIndex: Int, hit: SearchHit)
    )
        -> Bool
    {
        lhs.hit.rank != rhs.hit.rank ? lhs.hit.rank > rhs.hit.rank : lhs.unitIndex < rhs.unitIndex
    }

    /// `hits`, best first, grouped by scene; scenes are ordered by their best hit.
    private static func grouped(_ hits: [SearchHit]) -> [SceneHits] {
        struct SceneKey: Hashable {
            let version: SearchVersion
            let scene: SceneID
        }
        var order: [SceneKey] = []
        var groups: [SceneKey: [SearchHit]] = [:]
        for hit in hits {
            let key = SceneKey(version: hit.unit.version, scene: hit.unit.scene)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(hit)
        }
        return order.map { SceneHits(hits: groups[$0]!) }
    }
}

/// A keyword as one index compares it.
struct CompiledKeyword {
    enum Pattern: Hashable {
        /// `nil` if no word in the index has the key, so nothing can match.
        case word(Int32?)
        case phrase([Int32?])
    }

    let pattern: Pattern
    let comparison: Comparison

    /// How many words an occurrence spans.
    var width: Int {
        switch pattern {
        case .word: 1
        case .phrase(let words): words.count
        }
    }

    /// The query's keywords, without any that compare equal to an earlier one.
    static func distinct(_ query: SearchQuery, in index: KeywordSearch) -> [CompiledKeyword] {
        let sensitivity: SearchText.CaseSensitivity =
            query.options.contains(.matchCase) ? .sensitive : .insensitive
        let words = Comparison(
            sensitivity: sensitivity, endings: query.options.contains(.wholeWord) ? .significant : .ignored)
        let phrases = Comparison(sensitivity: sensitivity, endings: .significant)
        func key(_ word: String, _ comparison: Comparison) -> Int32? {
            index.keyIDs[comparison.key(Array(word.utf16))]
        }
        var seen: Set<[[UInt16]]> = []
        return query.keywords.compactMap { keyword in
            let pattern: Pattern
            let keys: [[UInt16]]
            switch keyword {
            case .word(let word):
                keys = [[0], words.key(Array(word.utf16))]
                pattern = .word(key(word, words))
            case .phrase(let phrase):
                keys = [[1]] + phrase.map { phrases.key(Array($0.utf16)) }
                pattern = .phrase(phrase.map { key($0, phrases) })
            }
            guard seen.insert(keys).inserted else { return nil }
            return CompiledKeyword(pattern: pattern, comparison: pattern.isWord ? words : phrases)
        }
    }
}

extension CompiledKeyword.Pattern {
    fileprivate var isWord: Bool {
        if case .word = self { true } else { false }
    }
}

/// Where a keyword occurs in a unit, as token indices.
struct Occurrence {
    let keyword: Int
    let first: Int
    let last: Int
}

/// What a unit matched, independent of the other units, so the rank can be recomputed as the
/// rarity of each keyword changes during the search.
struct UnitMatch {
    let unitIndex: Int
    /// Per keyword.
    let occurrenceCounts: [Int]
    let coverage: Int
    let tier: ProximityTier
    /// 1 when the matched words are adjacent, falling towards 0 as words come between them.
    let compactness: Double
    /// The fraction of neighbouring query keywords that also neighbour each other here.
    let adjacency: Double
    let matched: [Range<Int>]
    let differing: [Range<Int>]

    init?(_ unit: IndexedUnit, at unitIndex: Int, keywords: [CompiledKeyword], forms: [FormKeys]) {
        let occurrences = Self.occurrences(in: unit, keywords: keywords, forms: forms)
        guard !occurrences.isEmpty else { return nil }
        var counts = Array(repeating: 0, count: keywords.count)
        for occurrence in occurrences { counts[occurrence.keyword] += 1 }
        let coverage = counts.count { $0 > 0 }
        let sentence = { (occurrence: Occurrence) in unit.tokens[occurrence.first].sentence }
        let bySentence = Dictionary(grouping: occurrences, by: sentence).values
        let sentences = bySentence.filter { Set($0.map(\.keyword)).count == coverage }
        let tier: ProximityTier = sentences.isEmpty ? .paragraph : .sentence
        let window = (tier == .sentence ? Array(sentences) : [occurrences])
            .compactMap { Self.smallestWindow($0, coverage: coverage, keywordCount: keywords.count) }
            .min { $0.span < $1.span }!
        let matchedWidth = window.chosen.reduce(0) { $0 + keywords[$1.keyword].width }

        self.unitIndex = unitIndex
        occurrenceCounts = counts
        self.coverage = coverage
        self.tier = tier
        compactness = 1 / Double(1 + max(0, window.span - matchedWidth))
        adjacency = Self.adjacency(occurrences, tokens: unit.tokens, keywordCount: keywords.count)
        matched = Self.merged(
            occurrences.map { Int(unit.tokens[$0.first].start)..<Int(unit.tokens[$0.last].end) })
        differing = Self.differing(
            around: window.chosen, tokens: unit.tokens, matchedCounts: counts, keywords: keywords,
            occurrences: occurrences)
    }

    func hit(_ unit: SearchUnit, rarity: [Double], quality: MatchQuality) -> SearchHit {
        var fine = 0.0
        for (keyword, count) in occurrenceCounts.enumerated() where count > 0 {
            fine += rarity[keyword] * (1 + RankingWeights.repeats * log(Double(count)))
        }
        fine += RankingWeights.compactness * compactness + RankingWeights.adjacency * adjacency
        fine += RankingWeights.boost(unit.field)
        let highlights =
            matched.map { Highlight(range: $0, kind: .match) }
            + (quality == .near ? differing.map { Highlight(range: $0, kind: .differs) } : [])
        return SearchHit(
            unit: unit, rank: Rank(coverage: coverage, tier: tier, fine: FineScore(value: fine)),
            highlights: highlights.sorted { $0.range.lowerBound < $1.range.lowerBound })
    }

    private static func occurrences(in unit: IndexedUnit, keywords: [CompiledKeyword], forms: [FormKeys])
        -> [Occurrence]
    {
        var occurrences: [Occurrence] = []
        let tokens = unit.tokens
        for (keywordIndex, keyword) in keywords.enumerated() {
            switch keyword.pattern {
            case .word(nil):
                continue
            case .word(let id?):
                for (token, form) in unit.forms.enumerated() where forms[Int(form)][keyword.comparison] == id
                {
                    occurrences.append(Occurrence(keyword: keywordIndex, first: token, last: token))
                }
            case .phrase(let ids):
                guard !ids.contains(nil), ids.count <= tokens.count else { continue }
                for first in 0...(tokens.count - ids.count) {
                    let last = first + ids.count - 1
                    let matches =
                        tokens[first].sentence == tokens[last].sentence
                        && ids.indices.allSatisfy {
                            forms[Int(unit.forms[first + $0])][keyword.comparison] == ids[$0]
                        }
                    if matches {
                        occurrences.append(Occurrence(keyword: keywordIndex, first: first, last: last))
                    }
                }
            }
        }
        return occurrences.sorted { ($0.first, $0.keyword) < ($1.first, $1.keyword) }
    }

    private struct Window {
        let span: Int
        /// One occurrence of each matched keyword.
        let chosen: [Occurrence]
    }

    /// The fewest consecutive tokens holding an occurrence of every one of `coverage` keywords,
    /// with `occurrences` sorted by position.
    private static func smallestWindow(_ occurrences: [Occurrence], coverage: Int, keywordCount: Int)
        -> Window?
    {
        var counts = Array(repeating: 0, count: keywordCount)
        var present = 0
        var left = 0
        var best: Window?
        for right in occurrences.indices {
            counts[occurrences[right].keyword] += 1
            if counts[occurrences[right].keyword] == 1 { present += 1 }
            while present == coverage {
                let window = occurrences[left...right]
                let span = window.map(\.last).max()! - occurrences[left].first + 1
                if span < best?.span ?? .max {
                    var chosen: [Int: Occurrence] = [:]
                    for occurrence in window where chosen[occurrence.keyword] == nil {
                        chosen[occurrence.keyword] = occurrence
                    }
                    best = Window(span: span, chosen: chosen.values.sorted { $0.keyword < $1.keyword })
                }
                counts[occurrences[left].keyword] -= 1
                if counts[occurrences[left].keyword] == 0 { present -= 1 }
                left += 1
            }
        }
        return best
    }

    private static func adjacency(_ occurrences: [Occurrence], tokens: [SearchToken], keywordCount: Int)
        -> Double
    {
        guard keywordCount > 1 else { return 0 }
        struct Start: Hashable {
            let keyword: Int
            let token: Int
        }
        let starts = Set(occurrences.map { Start(keyword: $0.keyword, token: $0.first) })
        let adjacentPairs = (0..<(keywordCount - 1)).count { keyword in
            occurrences.contains { occurrence in
                let next = occurrence.last + 1
                return occurrence.keyword == keyword && next < tokens.count
                    && tokens[next].sentence == tokens[occurrence.last].sentence
                    && starts.contains(Start(keyword: keyword + 1, token: next))
            }
        }
        return Double(adjacentPairs) / Double(keywordCount - 1)
    }

    /// The words where the query has a missing keyword right next to a matched one: "paw" in
    /// "the bear paw" when the search was "bear claw". Each matched keyword's chosen occurrence
    /// is extended over the run of missing keywords beside it in the query, within its sentence.
    private static func differing(
        around chosen: [Occurrence], tokens: [SearchToken], matchedCounts: [Int], keywords: [CompiledKeyword],
        occurrences: [Occurrence]
    ) -> [Range<Int>] {
        var matchedTokens = Set<Int>()
        for occurrence in occurrences { matchedTokens.formUnion(occurrence.first...occurrence.last) }
        var differing = Set<Int>()
        for occurrence in chosen {
            let sentence = tokens[occurrence.first].sentence
            func mark(_ token: Int) {
                if tokens.indices.contains(token), tokens[token].sentence == sentence,
                    !matchedTokens.contains(token)
                {
                    differing.insert(token)
                }
            }
            var position = occurrence.last + 1
            for keyword in keywords.indices.dropFirst(occurrence.keyword + 1) {
                guard matchedCounts[keyword] == 0 else { break }
                for token in position..<(position + keywords[keyword].width) { mark(token) }
                position += keywords[keyword].width
            }
            position = occurrence.first
            for keyword in keywords.indices.prefix(occurrence.keyword).reversed() {
                guard matchedCounts[keyword] == 0 else { break }
                for token in (position - keywords[keyword].width)..<position { mark(token) }
                position -= keywords[keyword].width
            }
        }
        return differing.sorted().map { Int(tokens[$0].start)..<Int(tokens[$0].end) }
    }

    /// `ranges` sorted, with overlapping ones joined.
    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// The fine score's ingredients and their weights, in one place.
enum RankingWeights {
    /// Each further occurrence of a keyword adds this much of its rarity times the log of the
    /// count: diminishing returns.
    static let repeats = 0.25
    static let compactness = 2.0
    static let adjacency = 1.0

    static func boost(_ field: SearchField) -> Double {
        switch field {
        case .title: 1.0
        case .tags: 0.5
        case .body, .notes, .comment: 0
        }
    }

    /// Inverse document frequency over the units searched.
    static func rarity(unitsContaining: Int, of units: Int) -> Double {
        unitsContaining == 0 ? 0 : log(1 + Double(units) / Double(unitsContaining))
    }
}
