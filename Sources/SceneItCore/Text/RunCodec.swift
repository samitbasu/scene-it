import AppKit

/// Converts between paragraphs of runs (the model) and the `NSAttributedString` an
/// `NSTextStorage` holds (PLAN §3, "Text bridge"), for a scene's body and its notes. The
/// title is plain text in its own field (decision 0015), so it never passes through here.
///
/// Saving keeps only what a `Run` can express:
/// - A run's color comes from the palette-name attributes, never from `NSColor`: text
///   whose foreground color has no palette name (pasted from elsewhere, say) saves as
///   uncolored, which is black.
/// - Bold and italic come from the font's traits. The font itself, sizes, spacing, links,
///   underlines and any other attribute are dropped.
/// - Every line or paragraph separator (`Character.isLineBreak`) ends a paragraph.
/// - Object replacement characters (U+FFFC, where attachments sit) are removed, with or
///   without an `.attachment` (decision 0016).
/// - A lone UTF-16 surrogate, which `NSString` allows but `String` can't hold, becomes
///   U+FFFD.
/// - `Run` applies `CharacterPolicy` to its text, so what's saved is what `book.md` can
///   store: an emoji (or that U+FFFD) becomes `[?]`, `—` becomes `--`, a tab a space.
/// - Text with no line breaks and nothing left to save is no paragraphs, so `[[]]` (one
///   empty paragraph) saves as `[]`.
///
/// One of the model's rules (book format §7.5) is beyond the codec: comment ids must
/// exist in the scene's `comments`. `book.md` writes a comment's ranges from that list,
/// so save verification refuses a book with an id missing from it. Whoever accepts the
/// edit must remap or strip unknown ids (decision 0017);
/// `Paragraph.commentIDs(in:)` lists the ids to check.
///
/// Main-actor isolated, because the `NSTextStorage` it reads and fills is.
@MainActor
public enum RunCodec {
    public static func attributedString(forBody body: [Paragraph]) -> NSAttributedString {
        attributedString(body, role: .body)
    }

    public static func body(from text: NSAttributedString) -> [Paragraph] {
        paragraphs(from: text)
    }

    public static func attributedString(forNotes notes: [Paragraph]) -> NSAttributedString {
        attributedString(notes, role: .notes)
    }

    public static func notes(from text: NSAttributedString) -> [Paragraph] {
        paragraphs(from: text)
    }

    private static func attributedString(_ paragraphs: [Paragraph], role: ParagraphRole) -> NSAttributedString
    {
        let text = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: "\n", attributes: role.typingAttributes))
            }
            for run in paragraph.runs {
                text.append(
                    NSAttributedString(string: run.text, attributes: RunFormat(run).attributes(in: role)))
            }
        }
        return text
    }

    private static func paragraphs(from text: NSAttributedString) -> [Paragraph] {
        let string = text.string
        let lines = string.split(omittingEmptySubsequences: false, whereSeparator: \.isLineBreak)
        let paragraphs = lines.map { line in
            var runs: [Run] = []
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: string)
            text.enumerateAttributes(in: lineRange) { attributes, range, _ in
                // Slicing rounds an index inside a surrogate pair down, so a range that
                // splits a pair yields the whole scalar once and an empty piece.
                guard let bounds = Range(range, in: string) else { return }
                var piece = String(string[bounds])
                piece.removeAll(where: \.isObjectReplacement)
                guard !piece.isEmpty else { return }
                let format = RunFormat(attributes)
                if let last = runs.last, RunFormat(last) == format {
                    runs[runs.count - 1].text += piece
                } else {
                    runs.append(format.run(piece))
                }
            }
            return Paragraph(runs)
        }
        return paragraphs == [[]] ? [] : paragraphs
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

    init(_ attributes: [NSAttributedString.Key: Any]) {
        if let font = attributes[.font] as? NSFont {
            styles = TextStyle.styles(of: font)
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
