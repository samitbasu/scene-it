public enum TextStyle: String, CaseIterable, Hashable, Sendable {
    case bold, italic, strike
}

/// A stretch of text with uniform formatting. `book.md` writes the styles inline and the
/// colors, highlights and comments as ranges in the scene's `### Marks` and `### Comments`.
public struct Run: Hashable, Sendable {
    public var text: String
    public var styles: Set<TextStyle>
    public var color: TextColor?
    public var highlight: HighlightColor?
    public var comments: Set<CommentID>

    public init(
        _ text: String,
        styles: Set<TextStyle> = [],
        color: TextColor? = nil,
        highlight: HighlightColor? = nil,
        comments: Set<CommentID> = []
    ) {
        self.text = text
        self.styles = styles
        self.color = color
        self.highlight = highlight
        self.comments = comments
    }
}

/// A paragraph. One with no runs is empty: the writer pressed Return twice.
public struct Paragraph: Hashable, Sendable, ExpressibleByArrayLiteral {
    public var runs: [Run]

    public init(_ runs: [Run]) {
        self.runs = runs
    }

    public init(arrayLiteral runs: Run...) {
        self.runs = runs
    }

    public var text: String {
        runs.map(\.text).joined()
    }

    /// Every comment id the paragraphs' runs mention.
    public static func commentIDs(in paragraphs: [Paragraph]) -> Set<CommentID> {
        Set(paragraphs.lazy.flatMap(\.runs).flatMap(\.comments))
    }
}
