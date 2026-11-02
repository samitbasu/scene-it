import Foundation

/// How many words some text has. A word is what Foundation's word enumeration yields
/// (`String.EnumerationOptions.byWords`, Unicode word boundaries): runs of spaces and
/// punctuation aren't words, "don't" and "1,409" are one word each, and "well-known" is two.
public struct WordCount: Hashable, Comparable, Sendable {
    public let words: Int

    public init(words: Int) {
        self.words = words
    }

    public static let zero = WordCount(words: 0)

    /// Paragraph breaks always separate words.
    public init(_ paragraphs: [Paragraph]) {
        words = paragraphs.reduce(0) { total, paragraph in total + Self.count(paragraph.text) }
    }

    private static func count(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) {
            _, _, _, _ in count += 1
        }
        return count
    }

    public static func + (lhs: WordCount, rhs: WordCount) -> WordCount {
        WordCount(words: lhs.words + rhs.words)
    }

    public static func < (lhs: WordCount, rhs: WordCount) -> Bool {
        lhs.words < rhs.words
    }
}

extension BookScene {
    /// The body's words; the title isn't counted.
    public var wordCount: WordCount {
        WordCount(body)
    }
}

extension Book {
    /// The manuscript's words: every scene in the story, and none in the Boneyard (PLAN §7.3).
    public var manuscriptWordCount: WordCount {
        scenes.reduce(.zero) { $0 + $1.wordCount }
    }
}
