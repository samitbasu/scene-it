import Foundation
import Testing

@testable import SceneItCore

/// PLAN M5 (a): case, diacritics, word endings, quotes, and the options that override them.
@Suite struct SearchMatchingTests {
    @Test func caseIsIgnoredByDefault() async throws {
        let units = bodyUnits(["A bear.", "A BEAR.", "A Bear.", "A boar."])
        #expect(Set(try await foundTexts(units, "bEaR")) == ["A bear.", "A BEAR.", "A Bear."])
    }

    @Test func diacriticsAreIgnoredBothWays() async throws {
        let units = bodyUnits(["The caf\u{E9} opened.", "The cafe closed.", "The CAF\u{C9} burned."])
        #expect(try await foundTexts(units, "cafe").count == 3)
        #expect(try await foundTexts(units, "Caf\u{E9}").count == 3)
        #expect(
            try await foundTexts(units, "cafe", .matchCase).count == 2, "Match case keeps diacritics ignored")
    }

    @Test func aDecomposedQueryIsNormalizedLikeTheText() async throws {
        let units = bodyUnits(["The caf\u{E9} opened."])
        #expect(try await foundTexts(units, "cafe\u{301}") == ["The caf\u{E9} opened."])
    }

    @Test func simpleEnglishEndingsMatch() async throws {
        let units = bodyUnits([
            "one bear", "two bears", "the bear's den", "the Bears' den", "bearing north", "a beard",
        ])
        #expect(
            Set(try await foundTexts(units, "bear")) == [
                "one bear", "two bears", "the bear's den", "the Bears' den",
            ])
        #expect(Set(try await foundTexts(units, "bears")).count == 4, "endings are ignored on both sides")
    }

    @Test(arguments: [
        ("bear", "bear"), ("bears", "bear"), ("bear's", "bear"), ("it's", "it"), ("James's", "James"),
        ("ladies", "lady"), ("LADIES", "LADY"), ("ties", "tie"), ("boxes", "box"), ("kisses", "kiss"),
        ("churches", "church"), ("wishes", "wish"), ("buzzes", "buzz"), ("horses", "horse"), ("axes", "axe"),
        ("glass", "glass"), ("status", "status"), ("this", "this"), ("gas", "gas"), ("is", "is"),
        ("1990s", "1990"), ("BEARS", "BEAR"),
    ])
    func theStemmingRule(word: String, stem: String) {
        #expect(String(decoding: SearchText.stem(Array(word.utf16)), as: UTF16.self) == stem)
    }

    @Test func wordsSplitAtPunctuationNotJustSpaces() async throws {
        let units = bodyUnits(["a well-known face", "dawn--and then", "(bear)", "don't go"])
        #expect(try await foundTexts(units, "known") == ["a well-known face"])
        #expect(try await foundTexts(units, "dawn") == ["dawn--and then"])
        #expect(try await foundTexts(units, "bear") == ["(bear)"])
        #expect(try await foundTexts(units, "don't") == ["don't go"])
        #expect(try await foundTexts(units, "don").isEmpty, "an apostrophe between letters joins a word")
    }

    @Test func quotesMakeAnExactPhrase() async throws {
        let units = bodyUnits([
            "the bear claw", "the claw bear", "the bears claws", "the Bear, claw", "the bear. Claw",
            "bear and claw",
        ])
        #expect(Set(try await foundTexts(units, "\"bear claw\"")) == ["the bear claw", "the Bear, claw"])
        #expect(try await foundTexts(units, "\u{201C}bear claw\u{201D}").count == 2, "typographic quotes too")
        #expect(try await foundTexts(units, "\"bears\"") == ["the bears claws"], "no endings inside quotes")
        #expect(try await foundTexts(units, "\"bear claw").count == 2, "an open quote runs to the end")
    }

    @Test func aQueryMixesPhrasesAndWords() {
        let query = SearchQuery("old \"bear claw\" wolf \"\"")
        #expect(query.keywords == [.word("old"), .phrase(["bear", "claw"]), .word("wolf")])
    }

    @Test func matchCaseMakesCaseSignificantButKeepsEndings() async throws {
        let units = bodyUnits(["Bear", "Bears", "bear", "BEAR"])
        #expect(Set(try await foundTexts(units, "Bear", .matchCase)) == ["Bear", "Bears"])
        #expect(try await foundTexts(units, "\"bear\"", .matchCase) == ["bear"])
    }

    @Test func wholeWordDropsTheEndings() async throws {
        let units = bodyUnits(["bear", "Bear", "bears", "bear's"])
        #expect(Set(try await foundTexts(units, "bear", .wholeWord)) == ["bear", "Bear"])
        #expect(try await foundTexts(units, "Bear", [.wholeWord, .matchCase]) == ["Bear"])
    }

    @Test func highlightsAreUTF16RangesOfTheWholeWord() async throws {
        let units = bodyUnits(["Le caf\u{E9} des bears' amis, bear's."])
        let hit = try #require(hits(try await finalUpdate(units, "bear")).first)
        #expect(highlighted(hit) == ["bears", "bear's"])
        #expect(hit.highlights.map(\.range) == [12..<17, 25..<31])
    }

    @Test func everyKeywordIsHighlightedWhereverItOccurs() async throws {
        let units = bodyUnits(["The bear met a bear. Claw, the bear said."])
        let hit = try #require(hits(try await finalUpdate(units, "bear claw")).first)
        #expect(highlighted(hit) == ["bear", "bear", "Claw", "bear"])
    }

    @Test func overlappingKeywordsShareOneHighlight() async throws {
        let units = bodyUnits(["the bear claw"])
        let hit = try #require(hits(try await finalUpdate(units, "bear \"bear claw\"")).first)
        #expect(highlighted(hit) == ["bear claw"])
        #expect(hit.rank.coverage == 2)
    }

    @Test func aSentenceEndsAtTerminalPunctuationBeforeSpaceOrAtALineBreak() {
        func sentences(_ text: String) -> [Int32] {
            SearchText.tokens(Array(text.utf16)).map(\.sentence)
        }
        #expect(sentences("One two. Three") == [0, 0, 1])
        #expect(sentences("Stop!\" she said? Yes") == [0, 1, 1, 2])
        #expect(sentences("Pi is 3.14 e.g today") == [0, 0, 0, 0, 0, 0, 0])
        #expect(sentences("Mr. Smith") == [0, 1], "abbreviations end sentences")
        #expect(sentences("Well...\nno") == [0, 2])
        #expect(sentences("line\nbreak") == [0, 1])
    }

    @Test func anEmptyQueryFindsNothingAndCompletes() async throws {
        let update = try await finalUpdate(bodyUnits(["bear"]), " \"\" -- ")
        #expect(update.scenes.isEmpty)
        #expect(update.quality == .exact)
    }

    @Test func aRepeatedKeywordCountsOnce() async throws {
        let update = try await finalUpdate(bodyUnits(["the bear"]), "bear Bears bear")
        #expect(update.quality == .exact)
        #expect(hits(update).first?.rank.coverage == 1)
    }
}
