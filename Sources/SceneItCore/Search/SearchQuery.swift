/// The Search sheet's checkboxes (PLAN §9.1).
public struct SearchOptions: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Case is significant. (Model text is ASCII, so there are no diacritics to consider.)
    public static let matchCase = SearchOptions(rawValue: 1 << 0)
    /// A word matches only itself, without the endings `SearchText.stem` removes.
    public static let wholeWord = SearchOptions(rawValue: 1 << 1)
    /// Scene tags are searched too.
    public static let searchTags = SearchOptions(rawValue: 1 << 2)
}

/// One thing a query asks for. Coverage counts the distinct keywords a unit matches.
public enum Keyword: Hashable, Sendable {
    /// Matches a word with the same stem, or with `.wholeWord` the same word.
    case word(String)
    /// `"quoted"`: these words exactly, adjacent and in one sentence.
    case phrase([String])
}

public struct SearchQuery: Hashable, Sendable {
    /// In query order, as written; a word or phrase written twice appears twice.
    public let keywords: [Keyword]
    public let options: SearchOptions

    /// Words outside double quotes are separate keywords; the words inside each pair are a
    /// phrase, and a quote left open runs to the end. The text is admitted as the book's text is
    /// (`CharacterPolicy`), so typographic quotes delimit phrases too and words are split
    /// exactly as the units' are.
    public init(_ text: String, options: SearchOptions = []) {
        let parts = CharacterPolicy.admitted(text).split(separator: "\"", omittingEmptySubsequences: false)
        keywords = parts.enumerated().flatMap { index, part -> [Keyword] in
            let units = Array(part.utf16)
            let words = SearchText.tokens(units).map { String(decoding: units[$0.range], as: UTF16.self) }
            guard index.isMultiple(of: 2) else { return words.isEmpty ? [] : [.phrase(words)] }
            return words.map(Keyword.word)
        }
        self.options = options
    }
}
