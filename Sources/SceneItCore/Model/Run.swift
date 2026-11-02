public enum TextStyle: String, CaseIterable, Hashable, Sendable {
    case bold, italic, strike
}

/// A stretch of text with uniform formatting. `book.md` writes the styles inline and the
/// colors, highlights and comments as ranges in the scene's `### Marks` and `### Comments`.
public struct Run: Hashable, Sendable {
    /// One line of text `CharacterPolicy` admits. Every assignment applies the policy
    /// (`CharacterPolicy.admittedLine`), so a run can't hold what `book.md` can't store.
    public var text: String {
        didSet { text = CharacterPolicy.admittedLine(text) }
    }
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
        self.init(
            admitted: CharacterPolicy.admittedLine(text), styles: styles, color: color, highlight: highlight,
            comments: comments)
    }

    /// For text the caller has already admitted, like the parser's.
    init(
        admitted text: String, styles: Set<TextStyle>, color: TextColor?, highlight: HighlightColor?,
        comments: Set<CommentID>
    ) {
        self.text = text
        self.styles = styles
        self.color = color
        self.highlight = highlight
        self.comments = comments
    }

    /// Whether the two runs differ only in their text, so they can be one run.
    func hasSameFormat(as other: Run) -> Bool {
        styles == other.styles && color == other.color && highlight == other.highlight
            && comments == other.comments
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

    /// The same text with neighbouring runs of the same format merged, as `book.md`
    /// writes it.
    var withMaximalRuns: Paragraph {
        Paragraph(
            runs.reduce(into: []) { merged, run in
                if let last = merged.last, last.hasSameFormat(as: run) {
                    merged[merged.count - 1].text += run.text
                } else {
                    merged.append(run)
                }
            })
    }
}
