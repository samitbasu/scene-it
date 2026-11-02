import AppKit

/// A scene's page: the title paragraph, then the body.
public struct ScenePage: Hashable, Sendable {
    public var title: Paragraph
    public var body: [Paragraph]

    public init(title: Paragraph, body: [Paragraph]) {
        self.title = title
        self.body = body
    }
}

/// Converts between paragraphs of runs (the model) and the `NSAttributedString` an
/// `NSTextStorage` holds (PLAN §3, "Text bridge").
///
/// Saving keeps only what a `Run` can express. In particular a run's color comes from the
/// palette-name attributes, never from `NSColor`: text whose foreground color has no
/// palette name (pasted from elsewhere, say) saves as uncolored, which is black. Bold and
/// italic come from the font's traits; the font itself, sizes, spacing, links, underlines
/// and any other attribute are dropped. Every line or paragraph separator
/// (`Character.isNewline`) ends a paragraph, so the output always satisfies
/// `BookValidator`.
///
/// Main-actor isolated, like the text storage it serves: resolving fonts from several
/// threads at once has been seen to hang waiting on the font server.
@MainActor
public enum RunCodec {
    public static func attributedString(for page: ScenePage) -> NSAttributedString {
        attributedString([page.title] + page.body, layout: .page)
    }

    /// The first paragraph is the title, so a separator can't survive in the title: text
    /// after one becomes body paragraphs, and keeps the title's bold as a style.
    public static func page(from text: NSAttributedString) -> ScenePage {
        let paragraphs = paragraphs(from: text, layout: .page)
        return ScenePage(title: paragraphs[0], body: Array(paragraphs.dropFirst()))
    }

    public static func attributedString(forNotes notes: [Paragraph]) -> NSAttributedString {
        attributedString(notes, layout: .notes)
    }

    /// Empty text is no paragraphs, so `[[]]` (one empty paragraph) saves as `[]`.
    public static func notes(from text: NSAttributedString) -> [Paragraph] {
        text.length == 0 ? [] : paragraphs(from: text, layout: .notes)
    }

    private static func attributedString(_ paragraphs: [Paragraph], layout: TextLayout) -> NSAttributedString
    {
        let text = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let role = layout.role(ofParagraph: index)
            for run in paragraph.runs {
                text.append(
                    NSAttributedString(string: run.text, attributes: RunFormat(run).attributes(in: role)))
            }
            if index < paragraphs.count - 1 {
                text.append(NSAttributedString(string: "\n", attributes: role.typingAttributes))
            }
        }
        return text
    }

    private static func paragraphs(from text: NSAttributedString, layout: TextLayout) -> [Paragraph] {
        let string = text.string
        let lines = string.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return lines.enumerated().map { index, line in
            let role = layout.role(ofParagraph: index)
            var runs: [Run] = []
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: string)
            text.enumerateAttributes(in: lineRange) { attributes, range, _ in
                // Slicing rounds an index inside a surrogate pair down, so a range that
                // splits a pair yields the whole scalar once and an empty piece.
                guard let bounds = Range(range, in: string) else { return }
                let piece = String(string[bounds])
                guard !piece.isEmpty else { return }
                let format = RunFormat(attributes, in: role)
                if let last = runs.last, RunFormat(last) == format {
                    runs[runs.count - 1].text += piece
                } else {
                    runs.append(format.run(piece))
                }
            }
            return Paragraph(runs)
        }
    }
}

/// Which role each paragraph of an editor's text has.
private enum TextLayout {
    case page, notes

    func role(ofParagraph index: Int) -> ParagraphRole {
        switch self {
        case .page: index == 0 ? .title : .body
        case .notes: .notes
        }
    }
}

/// Everything about a run except its text: the one mapping between `Run` and attributes.
struct RunFormat: Hashable {
    var styles: Set<TextStyle> = []
    var color: TextColor?
    var highlight: HighlightColor?
    var comments: Set<CommentID> = []

    init() {}

    init(_ run: Run) {
        styles = run.styles
        color = run.color
        highlight = run.highlight
        comments = run.comments
    }

    init(_ attributes: [NSAttributedString.Key: Any], in role: ParagraphRole) {
        if let font = attributes[.font] as? NSFont {
            styles = role.styles(of: font)
        }
        if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
            styles.insert(.strike)
        }
        color = attributes[novel: NovelAttributes.TextColorAttribute.self]
        highlight = attributes[novel: NovelAttributes.HighlightAttribute.self]
        comments = attributes[novel: NovelAttributes.CommentsAttribute.self] ?? []
    }

    func run(_ text: String) -> Run {
        Run(text, styles: styles, color: color, highlight: highlight, comments: comments)
    }

    @MainActor
    func attributes(in role: ParagraphRole) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: role.font(styles),
            .paragraphStyle: role.paragraphStyle,
            .foregroundColor: PaletteColor(color).nsColor,
        ]
        if styles.contains(.strike) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        attributes[novel: NovelAttributes.TextColorAttribute.self] = color
        if let highlight {
            attributes[.backgroundColor] = highlight.nsColor
            attributes[novel: NovelAttributes.HighlightAttribute.self] = highlight
        }
        if !comments.isEmpty {
            attributes[novel: NovelAttributes.CommentsAttribute.self] = comments
        }
        return attributes
    }
}
