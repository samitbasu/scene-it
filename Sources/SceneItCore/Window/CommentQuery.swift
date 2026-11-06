/// What the comments panel's search field asks for (PLAN §8.1): plain words, all of which a
/// comment's text must hold, and `#color` tokens, any of which its color must be.
public struct CommentQuery: Hashable, Sendable {
    /// Lowercased, in the order typed.
    public let words: [String]
    /// The recognized colors, in the order first typed: the chips under the field.
    public let colors: [PaletteColor]
    /// The `#name` tokens naming no color, as typed (lowercased), for the field to flag.
    public let unknownColors: [String]

    public init(_ text: String) {
        var words: [String] = []
        var colors: [PaletteColor] = []
        var unknown: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard token.hasPrefix("#") else {
                words.append(token.lowercased())
                continue
            }
            let name = token.dropFirst()
            if name.isEmpty { continue }
            if let color = PaletteColor(named: name.utf8) {
                if !colors.contains(color) { colors.append(color) }
            } else if !unknown.contains(token.lowercased()) {
                unknown.append(token.lowercased())
            }
        }
        self.words = words
        self.colors = colors
        self.unknownColors = unknown
    }

    /// Whether the query asks for nothing, so every comment matches.
    public var isEmpty: Bool {
        words.isEmpty && colors.isEmpty
    }

    public func matches(_ comment: Comment) -> Bool {
        guard colors.isEmpty || colors.contains(comment.color) else { return false }
        let text = comment.text.lowercased()
        return words.allSatisfy(text.contains)
    }
}
