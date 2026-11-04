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

/// How search reads text: words, sentences, case and endings. Model text is printable ASCII
/// (decision 0028), so each character is one UTF-16 unit.
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
    enum CaseSensitivity: Int, Hashable, Sendable, CaseIterable {
        case insensitive
        case sensitive
    }

    /// `word` as search compares it: in lower case when `case` is `.insensitive`, otherwise as
    /// it is. Model text is ASCII, so there are no diacritics left to fold.
    static func folded(_ word: some Collection<UInt16>, _ sensitivity: CaseSensitivity) -> [UInt16] {
        sensitivity == .insensitive ? word.map(lower) : Array(word)
    }

    /// `word` reduced to a stem, so that "bear", "bears", "bear's" and "Bears'" share one.
    /// Suffixes are recognized whatever their case.
    /// 1. "news", "does" and the `contractions` are kept whole.
    /// 2. A possessive `'s` is removed and the rest is stemmed again ("James's" → "James" →
    ///    "Jame", the stem of "James" too).
    /// 3. Otherwise, only when at least 3 characters remain, one plural ending is removed:
    ///    - `es` after `ss`, `x`, `zz`, `ch`, `sh` or `o` ("kisses" → "kiss", "boxes" → "box",
    ///      "buzzes" → "buzz", "churches" → "church", "heroes" → "hero");
    ///    - otherwise `s`, unless it follows another `s` ("bears" → "bear", "sizes" → "size",
    ///      "menus" → "menu"; "glass" is kept, and so are "his" and "bus", too short).
    /// 4. A final `ie` becomes `y`, so "movie" and "movies" share "movy", and "lady" and "ladies"
    ///    share "lady". A final `oe` becomes `o` when at least 3 characters remain, so "shoe" and
    ///    "shoes" share "sho", as "hero" and "heroes" share "hero"; "toe" and "toes" share "toe".
    static func stem(_ word: [UInt16]) -> [UInt16] {
        let minimumStem = 3
        if keptWhole.contains(word.map(lower)) { return word }
        if let owner = possessor(word) { return stem(owner) }
        var stem = word
        if stem.count - 2 >= minimumStem,
            ["sses", "xes", "zzes", "ches", "shes", "oes"].contains(where: { endsWith(stem, $0) })
        {
            stem.removeLast(2)
        } else if stem.count - 1 >= minimumStem, endsWith(stem, "s"), !endsWith(stem, "ss") {
            stem.removeLast()
        }
        if stem.count >= 3, endsWith(stem, "ie") {
            let i = stem[stem.count - 2]
            stem.removeLast(2)
            stem.append(i == UInt16(ascii: "I") ? UInt16(ascii: "Y") : UInt16(ascii: "y"))
        } else if stem.count - 1 >= minimumStem, endsWith(stem, "oe") {
            stem.removeLast()
        }
        return stem
    }

    /// `word` without a final possessive `'s`, whatever its case ("James's" → "James"). A
    /// contraction such as "it's" isn't a possessive, so it's kept whole.
    static func withoutPossessive(_ word: [UInt16]) -> [UInt16] {
        possessor(word) ?? word
    }

    /// Words ending in `'s` that aren't possessives, in lower case.
    static let contractions: Set<[UInt16]> = Set(
        [
            "it's", "he's", "she's", "that's", "let's", "what's", "there's", "here's", "who's", "where's",
            "how's", "why's", "when's",
        ].map { Array($0.utf16) })

    private static let keptWhole = contractions.union([Array("news".utf16), Array("does".utf16)])

    /// What the possessive `word` belongs to ("bear" for "bear's"), or `nil` if it isn't one.
    private static func possessor(_ word: [UInt16]) -> [UInt16]? {
        guard endsWith(word, "'s"), !contractions.contains(word.map(lower)) else { return nil }
        return Array(word.dropLast(2))
    }

    /// Whether `word` ends with the lower-case `suffix`, whatever the case of `word`.
    private static func endsWith(_ word: [UInt16], _ suffix: String) -> Bool {
        let suffix = Array(suffix.utf16)
        return word.count >= suffix.count
            && zip(word.suffix(suffix.count), suffix).allSatisfy { lower($0) == $1 }
    }

    private static let apostrophe = UInt16(ascii: "'")
    private static let newline = UInt16(ascii: "\n")

    private static func isWordCharacter(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    private static func isSentenceTerminal(_ unit: UInt16) -> Bool {
        unit == UInt16(ascii: ".") || unit == UInt16(ascii: "!") || unit == UInt16(ascii: "?")
    }

    private static func isCloser(_ unit: UInt16) -> Bool {
        unit == UInt16(ascii: "\"") || unit == apostrophe || unit == UInt16(ascii: ")")
            || unit == UInt16(ascii: "]")
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == UInt16(ascii: " ") || unit == newline || unit == UInt16(ascii: "\t")
    }

    private static func lower(_ unit: UInt16) -> UInt16 {
        (0x41...0x5A).contains(unit) ? unit | 0x20 : unit
    }
}

extension UInt16 {
    fileprivate init(ascii scalar: Unicode.Scalar) {
        self.init(UInt8(ascii: scalar))
    }
}
