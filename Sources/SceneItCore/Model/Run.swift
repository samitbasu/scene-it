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
        hasSameLook(as: other) && comments == other.comments
    }

    /// Whether the two runs differ only in their text and comments, so they're drawn alike.
    func hasSameLook(as other: Run) -> Bool {
        styles == other.styles && color == other.color && highlight == other.highlight
    }
}

/// A paragraph. One with no runs is empty: the writer pressed Return twice.
public struct Paragraph: Hashable, Sendable, ExpressibleByArrayLiteral {
    /// Never holds an empty run: the initializers and every assignment drop them, since an
    /// empty run has nothing `book.md` could write. (Each assignment scans the runs once,
    /// so build a paragraph's runs in an array rather than appending one at a time.)
    public var runs: [Run] {
        didSet {
            if runs.contains(where: \.text.isEmpty) { runs.removeAll(where: \.text.isEmpty) }
        }
    }

    public init(_ runs: [Run]) {
        self.runs = runs.filter { !$0.text.isEmpty }
    }

    public init(arrayLiteral runs: Run...) {
        self.init(runs)
    }

    public var text: String {
        runs.map(\.text).joined()
    }

    /// Every comment id the paragraphs' runs mention.
    public static func commentIDs(in paragraphs: [Paragraph]) -> Set<CommentID> {
        Set(paragraphs.lazy.flatMap(\.runs).flatMap(\.comments))
    }

    /// The same text, carrying no comment but `known`.
    public func keepingComments(_ known: Set<CommentID>) -> Paragraph {
        changingComments { $0.formIntersection(known) }
    }

    /// The same text without the comments `ids`.
    public func removingComments(_ ids: Set<CommentID>) -> Paragraph {
        changingComments { $0.subtract(ids) }
    }

    /// The same text with no comments at all.
    public var uncommented: Paragraph {
        changingComments { $0 = [] }
    }

    /// Every run's comments changed by `change`, and the runs that then match merged; `self`
    /// if that changes no run's comments.
    private func changingComments(_ change: (inout Set<CommentID>) -> Void) -> Paragraph {
        let changed = runs.map { run in
            var run = run
            change(&run.comments)
            return run
        }
        return changed.map(\.comments) == runs.map(\.comments) ? self : Paragraph(changed).withMaximalRuns
    }

    /// The same text with neighbouring runs of the same format merged, as `book.md`
    /// writes it.
    var withMaximalRuns: Paragraph {
        var merged: [Run] = []
        var start = runs.startIndex
        while start < runs.endIndex {
            var end = start + 1
            while end < runs.endIndex, runs[end].hasSameFormat(as: runs[start]) {
                end += 1
            }
            let first = runs[start]
            merged.append(
                end == start + 1
                    ? first
                    : Run(
                        admitted: runs[start..<end].map(\.text).joined(), styles: first.styles,
                        color: first.color,
                        highlight: first.highlight, comments: first.comments))
            start = end
        }
        return Paragraph(merged)
    }
}
