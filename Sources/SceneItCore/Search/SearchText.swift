import Foundation

/// A word in a unit's text: a maximal run of letters and digits, which may hold an apostrophe
/// between two of them ("don't", "bear's"). Everything else separates words, so "well-known" and
/// "dawn--and" are two words each.
///
/// This deliberately differs from `WordCount`'s word (decision 0023), which is Word's
/// whitespace-delimited count: search must find "known" in "well-known" and "bear" in "bear,".
struct SearchToken: Hashable, Sendable {
    /// UTF-16 offsets into the unit's text.
    let start: Int32
    let end: Int32
    /// Equal for two tokens exactly when they're in the same sentence of the unit.
    let sentence: Int32

    var range: Range<Int> { Int(start)..<Int(end) }
}

/// How search reads text: words, sentences, folding and endings. Model text is printable
/// Latin-1 (decision 0022), so each character is one UTF-16 unit; strict ASCII (decision 0028)
/// will only shrink the tables.
enum SearchText {
    /// The words of `text`, each tagged with its sentence.
    ///
    /// A sentence ends at a line break, and after a run of `.`, `!` or `?` that is followed,
    /// once any closing `"`, `'`, `)` and `]` are skipped, by whitespace or the end of the text.
    /// So "Mr. Smith" is two sentences, while "e.g" and "3.5" end none.
    static func tokens(_ text: [UInt16]) -> [SearchToken] {
        var tokens: [SearchToken] = []
        var sentence: Int32 = 0
        var index = 0
        let count = text.count
        while index < count {
            let unit = text[index]
            if isWordCharacter(unit) {
                let start = index
                index += 1
                while index < count {
                    if isWordCharacter(text[index]) {
                        index += 1
                    } else if text[index] == apostrophe, index + 1 < count, isWordCharacter(text[index + 1]) {
                        index += 2
                    } else {
                        break
                    }
                }
                tokens.append(SearchToken(start: Int32(start), end: Int32(index), sentence: sentence))
            } else if unit == newline {
                sentence += 1
                index += 1
            } else if isSentenceTerminal(unit) {
                index += 1
                while index < count, isSentenceTerminal(text[index]) || isCloser(text[index]) {
                    index += 1
                }
                if index == count || isWhitespace(text[index]) { sentence += 1 }
            } else {
                index += 1
            }
        }
        return tokens
    }

    /// Whether case is significant when comparing words.
    enum CaseSensitivity: Hashable, Sendable {
        case insensitive
        case sensitive
    }

    /// `word` as search compares it: diacritics removed, and case folded when `case` is
    /// `.insensitive`, as Foundation's `.diacriticInsensitive` and `.caseInsensitive` folding
    /// does it (so `ß` folds to `ss`).
    static func folded(_ word: some Collection<UInt16>, _ sensitivity: CaseSensitivity) -> [UInt16] {
        let table = sensitivity == .insensitive ? Folding.insensitive : Folding.sensitive
        var folded: [UInt16] = []
        folded.reserveCapacity(word.count)
        for unit in word {
            if unit < 0x100 {
                folded.append(contentsOf: table[Int(unit)])
            } else {
                folded.append(unit)
            }
        }
        return folded
    }

    /// `word` without one simple English ending, so "bear", "bears", "bear's" and "Bears'"
    /// share a stem. Suffixes are recognized whatever their case; the first rule that applies
    /// wins:
    /// 1. A possessive `'s` is removed ("bear's" → "bear", "it's" → "it").
    /// 2. Otherwise, only when at least 3 characters remain:
    ///    - `ies` becomes `y` ("ladies" → "lady"; "ties" has too short a stem, so rule 2c
    ///      makes it "tie");
    ///    - `es` is removed after `ss`, `x`, `z`, `ch` or `sh` ("boxes" → "box",
    ///      "kisses" → "kiss", "churches" → "church");
    ///    - `s` is removed unless it follows `s`, `u` or `i` ("bears" → "bear",
    ///      "horses" → "horse"; "glass", "status" and "this" are kept).
    static func stem(_ word: [UInt16]) -> [UInt16] {
        func lower(_ unit: UInt16) -> UInt16 {
            (0x41...0x5A).contains(unit) ? unit | 0x20 : unit
        }
        func endsWith(_ suffix: String) -> Bool {
            let suffix = Array(suffix.utf16)
            return word.count >= suffix.count
                && zip(word.suffix(suffix.count), suffix).allSatisfy { lower($0) == $1 }
        }
        func letter(fromEnd offset: Int) -> UInt16? {
            word.count > offset ? lower(word[word.count - 1 - offset]) : nil
        }
        let minimumStem = 3
        if endsWith("'s") { return Array(word.dropLast(2)) }
        if endsWith("ies"), word.count - 3 + 1 >= minimumStem {
            let y: UInt16 =
                word[word.count - 3] == UInt16(ascii: "I") ? UInt16(ascii: "Y") : UInt16(ascii: "y")
            return Array(word.dropLast(3)) + [y]
        }
        if endsWith("es"), word.count - 2 >= minimumStem,
            endsWith("sses") || endsWith("xes") || endsWith("zes") || endsWith("ches") || endsWith("shes")
        {
            return Array(word.dropLast(2))
        }
        if endsWith("s"), word.count - 1 >= minimumStem,
            let before = letter(fromEnd: 1),
            ![UInt16(ascii: "s"), UInt16(ascii: "u"), UInt16(ascii: "i")].contains(before)
        {
            return Array(word.dropLast())
        }
        return word
    }

    private static let apostrophe = UInt16(ascii: "'")
    private static let newline = UInt16(ascii: "\n")

    private static func isWordCharacter(_ unit: UInt16) -> Bool {
        unit < 0x100 && Folding.wordCharacters[Int(unit)]
    }

    private static func isSentenceTerminal(_ unit: UInt16) -> Bool {
        unit == UInt16(ascii: ".") || unit == UInt16(ascii: "!") || unit == UInt16(ascii: "?")
    }

    private static func isCloser(_ unit: UInt16) -> Bool {
        unit == UInt16(ascii: "\"") || unit == apostrophe || unit == UInt16(ascii: ")")
            || unit == UInt16(ascii: "]")
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == UInt16(ascii: " ") || unit == newline || unit == UInt16(ascii: "\t") || unit == 0xA0
    }

    /// Per Latin-1 character, computed once from Foundation rather than written out by hand.
    private enum Folding {
        static let insensitive = table([.caseInsensitive, .diacriticInsensitive])
        static let sensitive = table([.diacriticInsensitive])
        static let wordCharacters: [Bool] = (0..<0x100).map { value in
            let properties = Unicode.Scalar(UInt8(value)).properties
            return properties.isAlphabetic || properties.generalCategory == .decimalNumber
        }

        private static func table(_ options: String.CompareOptions) -> [[UInt16]] {
            (0..<0x100).map { value in
                Array(
                    String(Character(Unicode.Scalar(UInt8(value)))).folding(options: options, locale: nil)
                        .utf16)
            }
        }
    }
}

extension UInt16 {
    fileprivate init(ascii scalar: Unicode.Scalar) {
        self.init(UInt8(ascii: scalar))
    }
}
