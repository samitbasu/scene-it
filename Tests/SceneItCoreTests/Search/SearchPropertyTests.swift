import Foundation
import Testing

@testable import SceneItCore

/// Seeded random units and queries, checked against a brute-force reading of the same rules.
@Suite struct SearchPropertyTests {
    private static let pieces = [
        "bear", "Bears", "bear's", "BEAR", "claw", "claws", "caf\u{E9}", "Cafe", "CAF\u{C9}", "don't",
        "well-known",
        "ladies", "lady", "box", "boxes", "the", "a", "and", "--", "...", ".", "!\"", ",", "\n", "Mr.",
        "3.14",
        "na\u{EF}ve", "naive", "(", ")",
    ]
    private static let queryWords = [
        "bear", "Bears", "claw", "cafe", "CAF\u{C9}", "don't", "known", "lady", "box", "the", "naive", "wolf",
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

    /// Where each distinct keyword occurs in `text`, read straight from the rules: per keyword, the
    /// token indices its occurrences start at.
    private static func occurrences(_ text: String, _ query: SearchQuery) -> [[UInt16]: [Int]] {
        let utf16 = Array(text.utf16)
        let tokens = SearchText.tokens(utf16)
        let sensitivity: SearchText.CaseSensitivity =
            query.options.contains(.matchCase) ? .sensitive : .insensitive
        let words = Comparison(
            sensitivity: sensitivity, endings: query.options.contains(.wholeWord) ? .significant : .ignored)
        let exact = Comparison(sensitivity: sensitivity, endings: .significant)
        func key(_ token: Int, _ comparison: Comparison) -> [UInt16] {
            comparison.key(Array(utf16[tokens[token].range]))
        }
        var found: [[UInt16]: [Int]] = [:]
        for keyword in query.keywords {
            let (identity, keys, comparison): ([UInt16], [[UInt16]], Comparison) =
                switch keyword {
                case .word(let word):
                    ([0] + words.key(Array(word.utf16)), [words.key(Array(word.utf16))], words)
                case .phrase(let phrase):
                    (
                        [1] + phrase.flatMap { exact.key(Array($0.utf16)) + [0x20] },
                        phrase.map { exact.key(Array($0.utf16)) },
                        exact
                    )
                }
            found[identity] = tokens.indices.filter { first in
                first + keys.count <= tokens.count
                    && tokens[first].sentence == tokens[first + keys.count - 1].sentence
                    && keys.indices.allSatisfy { key(first + $0, comparison) == keys[$0] }
            }
        }
        return found
    }

    @Test func highlightsCoverKeywordOccurrencesAndTheHitsAreTheRightUnits() async throws {
        var random = SplitMix64(seed: 30)
        var seen: Set<MatchQuality> = []
        for _ in 0..<300 {
            let testCase = Self.randomCase(&random)
            let query = testCase.query
            let result = try #require(await updates(KeywordSearch(units: testCase.units), query).last)

            let searched = testCase.units.filter { query.options.contains(.searchTags) || $0.field != .tags }
            let coverage = Dictionary(
                searched.map { ($0, Self.occurrences($0.text, query).values.count { !$0.isEmpty }) },
                uniquingKeysWith: max)
            let keywordCount = Self.occurrences("", query).count
            let best = coverage.values.max() ?? 0
            let expected = Set(
                coverage.filter { $0.value > 0 && (best < keywordCount ? true : $0.value == keywordCount) }
                    .keys)
            let found = result.scenes.flatMap(\.hits)
            #expect(Set(found.map(\.unit)) == expected, "query \(query)")
            #expect(result.quality == (best > 0 && best < keywordCount ? .near : .exact))

            for hit in found {
                let tokens = SearchText.tokens(Array(hit.unit.text.utf16))
                let starts = Set(
                    Self.occurrences(hit.unit.text, query).values.joined().map { Int(tokens[$0].start) })
                let length = hit.unit.text.utf16.count
                #expect(
                    zip(hit.highlights, hit.highlights.dropFirst()).allSatisfy {
                        $0.range.upperBound <= $1.range.lowerBound
                    })
                for highlight in hit.highlights {
                    #expect(highlight.range.lowerBound >= 0 && highlight.range.upperBound <= length)
                    #expect(
                        tokens.contains { Int($0.end) == highlight.range.upperBound }, "ends at a word's end")
                    if highlight.kind == .match {
                        #expect(starts.contains(highlight.range.lowerBound), "starts a keyword occurrence")
                    } else {
                        #expect(result.quality == .near)
                        #expect(!starts.contains(highlight.range.lowerBound))
                    }
                }
            }
            if !found.isEmpty { seen.insert(result.quality) }
            for scene in result.scenes {
                #expect(scene.hits.map(\.rank) == scene.hits.map(\.rank).sorted(by: >))
            }
            #expect(result.scenes.map(\.best.rank) == result.scenes.map(\.best.rank).sorted(by: >))
        }
        #expect(seen == [.exact, .near], "precondition: the cases exercise both qualities")
    }
}
