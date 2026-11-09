import Foundation

/// The page's selection as read aloud (PLAN §10.3): the selected text as one utterance, and the
/// way back from a range of the utterance to the text it was taken from. Ranges on both sides
/// count UTF-16 code units, as `NSString`, `NSTextStorage` and `AVSpeechSynthesizer` do.
public struct SpokenText: Equatable, Sendable {
    /// The selected ranges' text, in order, joined by line breaks.
    public let utterance: String
    private let pieces: [Piece]
    /// The utterance's sentences in order, each with the source ranges it highlights.
    private let sentences: [Sentence]

    /// One selected range, and where its text starts in the utterance.
    private struct Piece: Equatable, Sendable {
        let source: NSRange
        let start: Int

        var spoken: NSRange { NSRange(location: start, length: source.length) }
    }

    private struct Sentence: Equatable, Sendable {
        /// Its range of the utterance, with the spaces after it.
        let spoken: NSRange
        let highlighted: [NSRange]
    }

    private static let joiner = "\n"

    /// `nil` when nothing is selected: every range is empty.
    public init?(selecting ranges: [NSRange], in text: NSString) {
        let selected = ranges.map { $0.clamped(toLength: text.length) }.filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        guard !selected.isEmpty else { return nil }
        var utterance = ""
        var pieces: [Piece] = []
        for range in selected {
            if !pieces.isEmpty { utterance += Self.joiner }
            pieces.append(Piece(source: range, start: (utterance as NSString).length))
            utterance += text.substring(with: range)
        }
        self.utterance = utterance
        self.pieces = pieces
        let string = utterance as NSString
        var spans: [NSRange] = []
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length), options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            spans.append(range)
        }
        sentences = spans.map {
            Sentence(
                spoken: $0,
                highlighted: Self.source(of: Self.trimmingTrailingWhitespace($0, in: string), in: pieces))
        }
    }

    /// The text to highlight while the synthesizer speaks `spoken`, a range of the utterance
    /// (usually a word): the whole sentence holding it, without its trailing spaces, as ranges
    /// of the source text. A sentence the selection cuts is highlighted only as far as it's read.
    public func sourceRanges(ofSentenceAround spoken: NSRange) -> [NSRange] {
        let holding = sentences.first {
            $0.spoken.location <= spoken.location && spoken.location < NSMaxRange($0.spoken)
        }
        return holding?.highlighted
            ?? Self.source(of: spoken.clamped(toLength: (utterance as NSString).length), in: pieces)
    }

    private static func trimmingTrailingWhitespace(_ range: NSRange, in string: NSString) -> NSRange {
        var end = NSMaxRange(range)
        while end > range.location,
            let scalar = Unicode.Scalar(string.character(at: end - 1)),
            scalar.properties.isWhitespace
        {
            end -= 1
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    /// `spoken`'s parts that came from the source, as source ranges; the joiners between pieces
    /// came from nowhere.
    private static func source(of spoken: NSRange, in pieces: [Piece]) -> [NSRange] {
        pieces.compactMap { piece in
            guard let overlap = piece.spoken.intersection(spoken), overlap.length > 0 else { return nil }
            return NSRange(
                location: piece.source.location + overlap.location - piece.start, length: overlap.length)
        }
    }
}

extension NSRange {
    /// This range cut to text of `length` UTF-16 units, so a range from older text can't
    /// reach past the end.
    public func clamped(toLength length: Int) -> NSRange {
        let start = Swift.min(Swift.max(location, 0), length)
        return NSRange(location: start, length: Swift.min(self.length, length - start))
    }
}
