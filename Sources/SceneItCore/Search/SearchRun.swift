import Foundation

/// One search in progress over one or more indexes, ranked together: the units searched so far
/// and what they matched.
struct SearchRun {
    private let parts: [Part]
    private let options: SearchOptions
    /// The units this search reads: tag units only with `.searchTags`.
    private let unitCount: Int
    private let keywordCount: Int
    private var interval: Duration
    private var cursor = UnitLocation(part: 0, unit: 0)
    private(set) var unitsSearched = 0
    /// Per keyword, how many of the units searched contain it.
    private var unitsContaining: [Int]
    private var matches: [UnitMatch] = []

    /// An index and the query as it compares.
    private struct Part {
        let index: KeywordSearch
        let query: CompiledQuery
    }

    init(index: KeywordSearch, query: SearchQuery) {
        self.init(indexes: [index], query: query)
    }

    /// Every index compiles the query to the same keywords (`CompiledKeyword.distinct` tells
    /// keywords apart by the query alone), so the counts per keyword add up across indexes.
    init(indexes: [KeywordSearch], query: SearchQuery) {
        parts = indexes.map { Part(index: $0, query: CompiledQuery(query, in: $0)) }
        options = query.options
        interval = indexes.first?.updateInterval ?? .zero
        unitCount = indexes.reduce(0) { total, index in
            total
                + (query.options.contains(.searchTags)
                    ? index.units.count : index.units.count { !$0.unit.isTagSet })
        }
        keywordCount = CompiledKeyword.distinct(query, in: nil).count
        unitsContaining = Array(repeating: 0, count: keywordCount)
        if keywordCount == 0 { cursor = UnitLocation(part: parts.count, unit: 0) }
        skipEmptyParts()
    }

    private var isComplete: Bool { cursor.part == parts.count }

    /// Searches units until `interval` has passed or none are left, then reports everything found
    /// so far; `nil` as soon as the task is cancelled.
    ///
    /// Each update ranks every match so far, so the interval doubles after each one: the
    /// intermediate rankings then cost at most about as much as the final one.
    mutating func advance(on clock: some Clock<Duration> = ContinuousClock()) -> SearchUpdate? {
        let deadline = clock.now.advanced(by: interval)
        while !isComplete {
            guard !Task.isCancelled else { return nil }
            search(at: cursor)
            cursor.unit += 1
            skipEmptyParts()
            if clock.now >= deadline { break }
        }
        interval *= 2
        return update()
    }

    private mutating func skipEmptyParts() {
        while !isComplete, cursor.unit == parts[cursor.part].index.units.count {
            cursor = UnitLocation(part: cursor.part + 1, unit: 0)
        }
    }

    private func unit(at location: UnitLocation) -> IndexedUnit {
        parts[location.part].index.units[location.unit]
    }

    private mutating func search(at location: UnitLocation) {
        let unit = unit(at: location)
        guard options.contains(.searchTags) || !unit.unit.isTagSet else { return }
        unitsSearched += 1
        guard let match = UnitMatch(unit, at: location, query: parts[location.part].query) else { return }
        for (keyword, count) in match.occurrenceCounts.enumerated() where count > 0 {
            unitsContaining[keyword] += 1
        }
        matches.append(match)
    }

    /// Every match so far, best first and grouped by scene; scenes are ordered by their best hit,
    /// and equal ranks keep the order of the indexes and of the units in each.
    private func update() -> SearchUpdate {
        let quality: MatchQuality =
            matches.contains { $0.coverage == keywordCount } || matches.isEmpty ? .exact : .near
        let rarity = unitsContaining.map { RankingWeights.rarity(unitsContaining: $0, of: unitsSearched) }
        let shown = matches.filter { quality == .near || $0.coverage == keywordCount }
        let ranks = shown.map { $0.rank(rarity: rarity, source: unit(at: $0.location).unit.source) }
        let order = shown.indices.sorted {
            ranks[$0] != ranks[$1] ? ranks[$0] > ranks[$1] : shown[$0].location < shown[$1].location
        }
        struct SceneKey: Hashable {
            let part: Int
            let scene: Int
        }
        var groups: [[SearchHit]] = []
        var groupOfScene: [SceneKey: Int] = [:]
        for position in order {
            let location = shown[position].location
            let unit = unit(at: location)
            let hit = shown[position].hit(unit.unit, rank: ranks[position], quality: quality)
            let key = SceneKey(part: location.part, scene: unit.scene)
            if let group = groupOfScene[key] {
                groups[group].append(hit)
            } else {
                groupOfScene[key] = groups.count
                groups.append([hit])
            }
        }
        let progress: SearchProgress =
            isComplete ? .complete : .searching(unitsSearched: unitsSearched, of: unitCount)
        return SearchUpdate(scenes: groups.map(SceneHits.init(hits:)), quality: quality, progress: progress)
    }
}

/// Where a unit is in a search's indexes; ordered as the search reads them.
struct UnitLocation: Comparable {
    var part: Int
    var unit: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.part, lhs.unit) < (rhs.part, rhs.unit)
    }
}

/// A query as one index compares it.
struct CompiledQuery {
    let keywords: [CompiledKeyword]
    let forms: [FormKeys]
    /// Per form in the index, the word keyword it matches, or -1. Empty if no keyword is a word.
    let wordKeywordOfForm: [Int]
    /// The phrases all of whose words are in the index, so that they can match.
    let phrases: [(keyword: Int, ids: [Int32], comparison: Comparison)]

    init(_ query: SearchQuery, in index: KeywordSearch) {
        keywords = CompiledKeyword.distinct(query, in: index)
        forms = index.forms
        var keywordOfID: [Int32: Int] = [:]
        var phrases: [(keyword: Int, ids: [Int32], comparison: Comparison)] = []
        for (keyword, compiled) in keywords.enumerated() {
            switch compiled.pattern {
            case .word(let id?): keywordOfID[id] = keyword
            case .word(nil): break
            case .phrase(let ids):
                let known = ids.compactMap { $0 }
                if known.count == ids.count { phrases.append((keyword, known, compiled.comparison)) }
            }
        }
        let wordComparison = keywords.first { $0.pattern.isWord }?.comparison
        wordKeywordOfForm =
            keywordOfID.isEmpty || wordComparison == nil
            ? [] : index.forms.map { keywordOfID[$0[wordComparison!]] ?? -1 }
        self.phrases = phrases
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

    /// The query's keywords, without any that compare equal to an earlier one. Which they are
    /// depends on the query alone; without an index, no word is known.
    static func distinct(_ query: SearchQuery, in index: KeywordSearch?) -> [CompiledKeyword] {
        let sensitivity: SearchText.CaseSensitivity =
            query.options.contains(.matchCase) ? .sensitive : .insensitive
        let words = Comparison(
            sensitivity: sensitivity,
            endings: query.options.contains(.wholeWord) ? .possessiveIgnored : .ignored)
        let phrases = Comparison(sensitivity: sensitivity, endings: .significant)
        func key(_ word: String, _ comparison: Comparison) -> Int32? {
            index?.keyIDs[comparison.key(Array(word.utf16))]
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
/// rarity of each keyword changes during the search. Building one is linear in the unit's words
/// times the keywords.
struct UnitMatch {
    let location: UnitLocation
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

    init?(_ unit: IndexedUnit, at location: UnitLocation, query: CompiledQuery) {
        let occurrences = Self.occurrences(in: unit, query: query)
        guard !occurrences.isEmpty else { return nil }
        let keywords = query.keywords
        var counts = Array(repeating: 0, count: keywords.count)
        for occurrence in occurrences { counts[occurrence.keyword] += 1 }
        let coverage = counts.count { $0 > 0 }
        let sentences = Self.sentencesHoldingEveryKeyword(
            occurrences, tokens: unit.tokens, coverage: coverage)
        let tier: ProximityTier = sentences.isEmpty ? .paragraph : .sentence
        let window = (tier == .sentence ? sentences : [occurrences.indices])
            .compactMap {
                Self.smallestWindow(occurrences[$0], coverage: coverage, keywordCount: keywords.count)
            }
            .min { $0.span < $1.span }!
        let matchedWidth = window.chosen.reduce(0) { $0 + keywords[$1.keyword].width }

        self.location = location
        occurrenceCounts = counts
        self.coverage = coverage
        self.tier = tier
        compactness = 1 / Double(1 + max(0, window.span - matchedWidth))
        adjacency = Self.adjacency(occurrences, tokens: unit.tokens, keywordCount: keywords.count)
        matched = Self.merged(
            occurrences.map { Int(unit.tokens[$0.first].start)..<Int(unit.tokens[$0.last].end) })
        differing =
            coverage == keywords.count
            ? []
            : Self.differing(
                around: window.chosen, tokens: unit.tokens, matchedCounts: counts, keywords: keywords,
                occurrences: occurrences)
    }

    func rank(rarity: [Double], source: SearchSource) -> Rank {
        var fine = 0.0
        for (keyword, count) in occurrenceCounts.enumerated() where count > 0 {
            fine += rarity[keyword] * (1 + RankingWeights.repeats * log(Double(count)))
        }
        fine += RankingWeights.compactness * compactness + RankingWeights.adjacency * adjacency
        fine += RankingWeights.boost(source)
        return Rank(coverage: coverage, tier: tier, fine: FineScore(value: fine))
    }

    func hit(_ unit: SearchUnit, rank: Rank, quality: MatchQuality) -> SearchHit {
        let matches = matched.map { Highlight(range: $0, kind: .match) }
        guard quality == .near, !differing.isEmpty else {
            return SearchHit(unit: unit, rank: rank, highlights: matches)
        }
        let highlights = matches + differing.map { Highlight(range: $0, kind: .differs) }
        return SearchHit(
            unit: unit, rank: rank,
            highlights: highlights.sorted { $0.range.lowerBound < $1.range.lowerBound })
    }

    /// Sorted by position, then keyword.
    private static func occurrences(in unit: IndexedUnit, query: CompiledQuery) -> [Occurrence] {
        var occurrences: [Occurrence] = []
        if !query.wordKeywordOfForm.isEmpty {
            for (token, form) in unit.forms.enumerated() {
                let keyword = query.wordKeywordOfForm[Int(form)]
                if keyword >= 0 {
                    occurrences.append(Occurrence(keyword: keyword, first: token, last: token))
                }
            }
        }
        guard !query.phrases.isEmpty else { return occurrences }
        let tokens = unit.tokens
        for phrase in query.phrases where phrase.ids.count <= tokens.count {
            for first in 0...(tokens.count - phrase.ids.count) {
                let last = first + phrase.ids.count - 1
                let matches =
                    tokens[first].sentence == tokens[last].sentence
                    && phrase.ids.indices.allSatisfy {
                        query.forms[Int(unit.forms[first + $0])][phrase.comparison] == phrase.ids[$0]
                    }
                if matches {
                    occurrences.append(Occurrence(keyword: phrase.keyword, first: first, last: last))
                }
            }
        }
        return occurrences.sorted { ($0.first, $0.keyword) < ($1.first, $1.keyword) }
    }

    /// The runs of `occurrences` in one sentence that hold all `coverage` matched keywords.
    private static func sentencesHoldingEveryKeyword(
        _ occurrences: [Occurrence], tokens: [SearchToken], coverage: Int
    ) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var seenInRun: [Int: Int] = [:]
        var start = 0
        while start < occurrences.count {
            let sentence = tokens[occurrences[start].first].sentence
            var end = start
            var distinct = 0
            while end < occurrences.count, tokens[occurrences[end].first].sentence == sentence {
                if seenInRun.updateValue(start, forKey: occurrences[end].keyword) != start { distinct += 1 }
                end += 1
            }
            if distinct == coverage { runs.append(start..<end) }
            start = end
        }
        return runs
    }

    private struct Window {
        let span: Int
        /// One occurrence of each matched keyword.
        let chosen: [Occurrence]
    }

    /// The fewest consecutive tokens holding an occurrence of every one of `coverage` keywords,
    /// with `occurrences` sorted by position. Linear in the occurrences times the keywords.
    private static func smallestWindow(
        _ occurrences: ArraySlice<Occurrence>, coverage: Int, keywordCount: Int
    )
        -> Window?
    {
        var counts = Array(repeating: 0, count: keywordCount)
        /// Each keyword's latest occurrence so far, which ends furthest since a keyword's
        /// occurrences all have the same width.
        var latest = Array(repeating: 0, count: keywordCount)
        var present = 0
        var left = occurrences.startIndex
        var best: (span: Int, left: Int, right: Int)?
        for right in occurrences.indices {
            let keyword = occurrences[right].keyword
            counts[keyword] += 1
            if counts[keyword] == 1 { present += 1 }
            latest[keyword] = right
            while present == coverage {
                var end = 0
                for keyword in counts.indices where counts[keyword] > 0 {
                    end = max(end, occurrences[latest[keyword]].last)
                }
                let span = end - occurrences[left].first + 1
                if span < best?.span ?? .max { best = (span, left, right) }
                counts[occurrences[left].keyword] -= 1
                if counts[occurrences[left].keyword] == 0 { present -= 1 }
                left += 1
            }
        }
        guard let best else { return nil }
        var chosen: [Int: Occurrence] = [:]
        for occurrence in occurrences[best.left...best.right] where chosen[occurrence.keyword] == nil {
            chosen[occurrence.keyword] = occurrence
        }
        return Window(span: best.span, chosen: chosen.values.sorted { $0.keyword < $1.keyword })
    }

    private static func adjacency(_ occurrences: [Occurrence], tokens: [SearchToken], keywordCount: Int)
        -> Double
    {
        guard keywordCount > 1 else { return 0 }
        var adjacent = Array(repeating: false, count: keywordCount - 1)
        for (position, occurrence) in occurrences.enumerated() where occurrence.keyword < keywordCount - 1 {
            let next = occurrence.last + 1
            guard !adjacent[occurrence.keyword], next < tokens.count,
                tokens[next].sentence == tokens[occurrence.last].sentence
            else { continue }
            for later in occurrences[(position + 1)...] {
                if later.first > next { break }
                if later.first == next, later.keyword == occurrence.keyword + 1 {
                    adjacent[occurrence.keyword] = true
                    break
                }
            }
        }
        return Double(adjacent.count { $0 }) / Double(keywordCount - 1)
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

    /// `ranges`, sorted by their starts, with overlapping ones joined.
    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges {
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

    static func boost(_ source: SearchSource) -> Double {
        switch source {
        case .scene(_, .title): 1.0
        case .scene(_, .tags), .copyTags: 0.5
        case .scene(_, .body), .scene(_, .notes), .scene(_, .comment): 0
        }
    }

    /// Inverse document frequency over the units searched.
    static func rarity(unitsContaining: Int, of units: Int) -> Double {
        unitsContaining == 0 ? 0 : log(1 + Double(units) / Double(unitsContaining))
    }
}
