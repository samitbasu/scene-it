import Foundation
import Testing

@testable import SceneItCore

/// The page's selection as an utterance, and the synthesizer's ranges mapped back to the page
/// (PLAN §10.3). Offsets on both sides are UTF-16, as `willSpeakRangeOfSpeechString` reports them.
struct SpokenTextTests {
    private static func range(of part: String, in text: String) throws -> NSRange {
        let found = (text as NSString).range(of: part)
        try #require(found.location != NSNotFound, "precondition: \"\(part)\" is in the text")
        return found
    }

    @Test func nothingSelectedIsNothingToRead() {
        let text = "One. Two." as NSString
        #expect(SpokenText(selecting: [], in: text) == nil)
        #expect(SpokenText(selecting: [NSRange(location: 3, length: 0)], in: text) == nil)
    }

    @Test func theUtteranceIsTheSelectionAlone() throws {
        let text = "The ferry left. Mara watched."
        let selection = try Self.range(of: "ferry left. Mara", in: text)
        let spoken = try #require(SpokenText(selecting: [selection], in: text as NSString))
        #expect(spoken.utterance == "ferry left. Mara")
    }

    /// The selection starts mid-sentence, mid-paragraph: its first sentence is highlighted from
    /// where the reading starts, the next one whole without the space after it, and the last as
    /// far as the selection goes.
    @Test func aWordMapsToItsSentenceOnThePage() throws {
        let text = "He found the letter. The tide was turning. Mara watched.\nDawn came."
        let selection = try Self.range(of: "the letter. The tide was turning. Mara", in: text)
        try #require(selection.location > 0, "precondition: the selection starts mid-paragraph")
        let spoken = try #require(SpokenText(selecting: [selection], in: text as NSString))

        let letter = try Self.range(of: "letter", in: spoken.utterance)
        #expect(
            spoken.sourceRanges(ofSentenceAround: letter) == [try Self.range(of: "the letter.", in: text)])

        let tide = try Self.range(of: "tide", in: spoken.utterance)
        #expect(
            spoken.sourceRanges(ofSentenceAround: tide) == [
                try Self.range(of: "The tide was turning.", in: text)
            ])

        let mara = try Self.range(of: "Mara", in: spoken.utterance)
        #expect(spoken.sourceRanges(ofSentenceAround: mara) == [try Self.range(of: "Mara", in: text)])
    }

    /// An emoji is two UTF-16 units, and its skin tone two more; a decomposed é is two scalars.
    /// The page's text is ASCII (ADR 0028), but the mapping mustn't depend on it.
    @Test func offsetsCountUTF16UnitsThroughEmojiAndComposedCharacters() throws {
        let text = "Cafe\u{301} 👋🏽 opens. Re\u{301}sume\u{301} 🇫🇷 next. End."
        let selection = try Self.range(of: "👋🏽 opens. Re\u{301}sume\u{301} 🇫🇷 next.", in: text)
        try #require(selection.location == 6, "precondition: the decomposed é is two units")
        let spoken = try #require(SpokenText(selecting: [selection], in: text as NSString))

        let next = try Self.range(of: "next", in: spoken.utterance)
        #expect(
            spoken.sourceRanges(ofSentenceAround: next)
                == [try Self.range(of: "Re\u{301}sume\u{301} 🇫🇷 next.", in: text)])
        let opens = try Self.range(of: "opens", in: spoken.utterance)
        #expect(spoken.sourceRanges(ofSentenceAround: opens) == [try Self.range(of: "👋🏽 opens.", in: text)])
    }

    @Test func aParagraphBreakEndsASentence() throws {
        let text = "A line without a stop\nThe ferry left."
        let spoken = try #require(
            SpokenText(
                selecting: [NSRange(location: 0, length: (text as NSString).length)], in: text as NSString))
        let stop = try Self.range(of: "stop", in: spoken.utterance)
        #expect(
            spoken.sourceRanges(ofSentenceAround: stop) == [
                try Self.range(of: "A line without a stop", in: text)
            ])
    }

    /// A selection of several ranges reads them in text order, a line break between.
    @Test func severalSelectedRangesReadInTextOrder() throws {
        let text = "Alpha one. Beta two. Gamma three."
        let beta = try Self.range(of: "Beta two", in: text)
        let alpha = try Self.range(of: "Alpha", in: text)
        let spoken = try #require(SpokenText(selecting: [beta, alpha], in: text as NSString))
        #expect(spoken.utterance == "Alpha\nBeta two")

        let two = try Self.range(of: "two", in: spoken.utterance)
        #expect(spoken.sourceRanges(ofSentenceAround: two) == [beta])
    }

    /// A sentence the synthesizer reads across the joiner maps to its part in each range.
    @Test func aSentenceAcrossTwoRangesMapsToBoth() throws {
        let text = "Alpha one and beta two."
        let alpha = try Self.range(of: "Alpha one", in: text)
        let beta = try Self.range(of: "beta two", in: text)
        let spoken = try #require(SpokenText(selecting: [alpha, beta], in: text as NSString))
        let whole = NSRange(location: 0, length: (spoken.utterance as NSString).length)
        #expect(spoken.source(of: whole) == [alpha, beta], "the joiner maps to nothing")
    }

    @Test func aRangePastTheTextIsCut() throws {
        let text = "Short." as NSString
        let spoken = try #require(SpokenText(selecting: [NSRange(location: 2, length: 40)], in: text))
        #expect(spoken.utterance == "ort.")
        #expect(
            spoken.sourceRanges(ofSentenceAround: NSRange(location: 0, length: 3)) == [
                NSRange(location: 2, length: 4)
            ])
    }
}
