import Foundation
import Testing

@testable import SceneItCore

/// Seeded random units and queries, checked against `Oracle`: the documented rules written again
/// from scratch, simply and slowly, sharing no code with the engine but the query parser.
@Suite struct SearchPropertyTests {
    private static let pieces = [
        "bear", "Bears", "bear's", "BEAR", "claw", "claws", "caf\u{E9}", "Cafe", "CAF\u{C9}", "don't",
        "well-known", "ladies", "lady", "box", "boxes", "the", "a", "and", "--", "...", ".", "!\"", ",", "\n",
        "Mr.", "3.14", "na\u{EF}ve", "naive", "(", ")", "James", "James's", "Jameses", "movie", "movies",
        "heroes",
        "hero",
        "news", "sizes", "size", "glass", "shoe", "shoes", "toe", "toes", "canoes",
    ]
    private static let queryWords = [
        "bear", "Bears", "claw", "cafe", "CAF\u{C9}", "don't", "known", "lady", "box", "the", "naive", "wolf",
        "James", "movie", "hero", "news", "size", "glass", "shoes", "canoe", "toe",
    ]

    private struct Case {
        let units: [SearchUnit]
        let query: SearchQuery
    }

    private static func randomCase(_ random: inout SplitMix64) -> Case {
        let units = (0..<Int.random(in: 1...12, using: &random)).map { index in
            let text = (0..<Int.random(in: 0...14, using: &random)).map { _ in
                pieces.randomElement(using: &random)! + (Bool.random(using: &random) ? " " : "")
            }.joined()
            let field: SearchField =
                Int.random(in: 0..<5, using: &random) == 0 ? .tags : .body(paragraph: index)
            return unit(text, field: field, scene: "s\(index % 4)", number: index % 4 + 1)
        }
        var text = (0..<Int.random(in: 1...3, using: &random)).map { _ in
            queryWords.randomElement(using: &random)!
        }
        if Bool.random(using: &random) {
            text.append(
                "\"\(queryWords.randomElement(using: &random)!) \(queryWords.randomElement(using: &random)!)\""
            )
        }
        let options = SearchOptions(rawValue: Int.random(in: 0..<8, using: &random))
        return Case(
            units: units.filter { !$0.text.isEmpty },
            query: SearchQuery(text.joined(separator: " "), options: options))
    }

    /// The rules of `SearchText` and `SearchRun`, as their documentation states them.
    private struct Oracle {
        struct Word {
            let range: Range<Int>
            let text: String
            let sentence: Int
        }

        struct Reading {
            /// Per distinct keyword, the character ranges of its occurrences.
            let occurrences: [[Range<Int>]]
            let words: [Word]

            var coverage: Int { occurrences.count { !$0.isEmpty } }

            var tier: ProximityTier {
                let sentenceAt = Dictionary(
                    uniqueKeysWithValues: words.map { ($0.range.lowerBound, $0.sentence) })
                let sentences = occurrences.filter { !$0.isEmpty }.map {
                    Set($0.map { sentenceAt[$0.lowerBound]! })
                }
                let shared = sentences.dropFirst().reduce(sentences.first ?? []) { $0.intersection($1) }
                return shared.isEmpty ? .paragraph : .sentence
            }
        }

        let query: SearchQuery

        static func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber
        }

        static func words(_ text: String) -> [Word] {
            let characters = Array(text)
            precondition(characters.count == text.utf16.count, "test text is one UTF-16 unit per character")
            var words: [Word] = []
            var sentence = 0
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if isWordCharacter(character) {
                    var end = index + 1
                    while end < characters.count,
                        isWordCharacter(characters[end])
                            || (characters[end] == "'" && end + 1 < characters.count
                                && isWordCharacter(characters[end + 1]))
                    {
                        end += 1
                    }
                    words.append(
                        Word(range: index..<end, text: String(characters[index..<end]), sentence: sentence))
                    index = end
                } else if character == "\n" {
                    sentence += 1
                    index += 1
                } else if ".!?".contains(character) {
                    var end = index + 1
                    while end < characters.count, ".!?\"')]".contains(characters[end]) { end += 1 }
                    if end == characters.count || characters[end].isWhitespace { sentence += 1 }
                    index = end
                } else {
                    index += 1
                }
            }
            return words
        }

        static func stem(_ word: String) -> String {
            let lower = word.lowercased()
            if lower == "news" || lower == "does" { return word }
            if lower.hasSuffix("'s") { return stem(withoutPossessive(word)) }
            var stem = word
            if stem.count >= 5,
                ["sses", "xes", "zzes", "ches", "shes", "oes"].contains(where: { lower.hasSuffix($0) })
            {
                stem = String(stem.dropLast(2))
            } else if stem.count >= 4, lower.hasSuffix("s"), !lower.hasSuffix("ss") {
                stem = String(stem.dropLast())
            }
            if stem.count >= 3, stem.lowercased().hasSuffix("ie") {
                stem = String(stem.dropLast(2)) + (stem.dropLast().last == "I" ? "Y" : "y")
            } else if stem.count >= 4, stem.lowercased().hasSuffix("oe") {
                stem = String(stem.dropLast())
            }
            return stem
        }

        static func withoutPossessive(_ word: String) -> String {
            word.lowercased().hasSuffix("'s") ? String(word.dropLast(2)) : word
        }

        func folded(_ word: String) -> String {
            query.options.contains(.matchCase) ? word : word.lowercased()
        }

        func wordKey(_ word: String) -> String {
            query.options.contains(.wholeWord)
                ? Self.withoutPossessive(folded(word)) : Self.stem(folded(word))
        }

        /// Each distinct keyword, as the keys its words must have.
        var keywords: [[String]] {
            var seen: [[String]] = []
            for keyword in query.keywords {
                let keys: [String] =
                    switch keyword {
                    case .word(let word): ["word", wordKey(word)]
                    case .phrase(let phrase): ["phrase"] + phrase.map(folded)
                    }
                if !seen.contains(keys) { seen.append(keys) }
            }
            return seen
        }

        func read(_ text: String) -> Reading {
            let words = Self.words(text)
            let occurrences = keywords.map { keys -> [Range<Int>] in
                if keys[0] == "word" {
                    return words.filter { wordKey($0.text) == keys[1] }.map(\.range)
                }
                let phrase = Array(keys.dropFirst())
                guard words.count >= phrase.count else { return [] }
                return (0...(words.count - phrase.count)).compactMap { first in
                    let run = words[first..<(first + phrase.count)]
                    guard Set(run.map(\.sentence)).count == 1, run.map({ folded($0.text) }) == phrase else {
                        return nil
                    }
                    return run.first!.range.lowerBound..<run.last!.range.upperBound
                }
            }
            return Reading(occurrences: occurrences, words: words)
        }

        static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
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

    @Test func theOracleReadsTheDocumentedExamples() {
        #expect(Oracle.words("Stop!\" she said? Yes").map(\.sentence) == [0, 1, 1, 2])
        #expect(Oracle.words("don't well-known").map(\.text) == ["don't", "well", "known"])
        #expect(
            ["James's", "heroes", "movies", "news", "sizes", "glass"].map(Oracle.stem) == [
                "Jame", "hero", "movy", "news", "size", "glass",
            ])
    }

    @Test func theHitsAndTheirHighlightsAreExactlyWhatTheRulesSay() async throws {
        var random = SplitMix64(seed: 30)
        var seen: Set<MatchQuality> = []
        for _ in 0..<300 {
            let testCase = Self.randomCase(&random)
            let query = testCase.query
            let oracle = Oracle(query: query)
            let result = try #require(await updates(KeywordSearch(units: testCase.units), query).last)

            let searched = testCase.units.filter { query.options.contains(.searchTags) || $0.field != .tags }
            let readings = Dictionary(
                searched.map { ($0, oracle.read($0.text)) }, uniquingKeysWith: { first, _ in first })
            let keywordCount = oracle.keywords.count
            let best = readings.values.map(\.coverage).max() ?? 0
            let expected = Set(
                readings.filter {
                    $0.value.coverage > 0 && (best < keywordCount || $0.value.coverage == keywordCount)
                }
                .keys)
            let found = result.scenes.flatMap(\.hits)
            #expect(Set(found.map(\.unit)) == expected, "query \(query)")
            #expect(result.quality == (best > 0 && best < keywordCount ? .near : .exact))

            for hit in found {
                let reading = try #require(readings[hit.unit])
                #expect(hit.rank.coverage == reading.coverage, "\(hit.unit.text) for \(query)")
                #expect(hit.rank.tier == reading.tier, "\(hit.unit.text) for \(query)")
                let matches = hit.highlights.filter { $0.kind == .match }.map(\.range)
                #expect(
                    matches == Oracle.merged(reading.occurrences.flatMap { $0 }),
                    "every occurrence, and only those")
                for differing in hit.highlights.filter({ $0.kind == .differs }).map(\.range) {
                    #expect(result.quality == .near)
                    #expect(reading.words.contains { $0.range == differing }, "a whole word")
                    #expect(!matches.contains { $0.overlaps(differing) })
                }
                #expect(
                    zip(hit.highlights, hit.highlights.dropFirst()).allSatisfy {
                        $0.range.upperBound <= $1.range.lowerBound
                    })
            }
            if !found.isEmpty { seen.insert(result.quality) }
            func coarse(_ hit: SearchHit) -> [Int] { [hit.rank.coverage, hit.rank.tier.rawValue] }
            for scene in result.scenes {
                #expect(scene.hits.map(\.rank) == scene.hits.map(\.rank).sorted(by: >))
                let ranks = scene.hits.map(coarse)
                #expect(zip(ranks, ranks.dropFirst()).allSatisfy { !$0.lexicographicallyPrecedes($1) })
            }
            #expect(result.scenes.map(\.best.rank) == result.scenes.map(\.best.rank).sorted(by: >))
        }
        #expect(seen == [.exact, .near], "precondition: the cases exercise both qualities")
    }
}
