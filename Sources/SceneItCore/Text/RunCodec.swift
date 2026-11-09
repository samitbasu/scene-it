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
public enum RunCodec {
    public static func attributedString(forBody body: [Paragraph]) -> NSAttributedString {
        attributedString(body, in: .body)
    }

    public static func body(from text: NSAttributedString) -> [Paragraph] {
        paragraphs(from: text)
    }

    public static func attributedString(forNotes notes: [Paragraph]) -> NSAttributedString {
        attributedString(notes, in: .notes)
    }

    public static func notes(from text: NSAttributedString) -> [Paragraph] {
        paragraphs(from: text)
    }

    public static func attributedString(_ paragraphs: [Paragraph], in part: TextPart) -> NSAttributedString {
        attributedString(paragraphs, role: part.role)
    }

    /// The paragraphs of a body or notes that reads as `text`; both parts read alike.
    public static func paragraphs(from text: NSAttributedString) -> [Paragraph] {
        let lines = lines(from: text)
        return lines == [[]] ? [] : lines
    }

    /// A scene's paragraphs as print puts them out: the title as its heading, and the typography
    /// smartened (decision 0022), which the editors never do.
    static func attributedString(forOutput paragraphs: [OutputParagraph]) -> NSAttributedString {
        attributedString(paragraphs.map { ($0.kind.role, $0.runs) }, punctuation: .smartened)
    }

    private static func attributedString(_ paragraphs: [Paragraph], role: ParagraphRole) -> NSAttributedString
    {
        attributedString(paragraphs.map { (role, $0.runs) }, punctuation: .asStored)
    }

    private enum Punctuation {
        case asStored, smartened
    }

    /// Each stretch of paragraphs in one role is styled by that role.
    private static func attributedString(
        _ paragraphs: [(role: ParagraphRole, runs: [Run])], punctuation: Punctuation
    ) -> NSAttributedString {
        let text = NSMutableAttributedString()
        var stretches: [(role: ParagraphRole, start: Int)] = []
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 {
                text.append(
                    NSAttributedString(string: "\n", attributes: paragraphs[index - 1].role.typingAttributes))
            }
            if stretches.last?.role != paragraph.role { stretches.append((paragraph.role, text.length)) }
            let unit =
                switch punctuation {
                case .asStored: nil as SmartUnit?
                case .smartened: SmartUnit(paragraph.runs.map(\.text).joined())
                }
            var offset = 0
            for run in paragraph.runs {
                let length = run.text.unicodeScalars.count
                let shown = unit?.piece(offset..<offset + length) ?? run.text
                offset += length
                text.append(
                    NSAttributedString(
                        string: shown, attributes: RunFormat(run).attributes(in: paragraph.role)))
            }
        }
        for (index, stretch) in stretches.enumerated() {
            let end = index + 1 < stretches.count ? stretches[index + 1].start : text.length
            stretch.role.styleParagraphs(
                of: text, around: NSRange(location: stretch.start, length: end - stretch.start))
        }
        return text
    }

    /// One paragraph per line of `text`, so text with no line breaks is one paragraph.
    static func lines(from text: NSAttributedString) -> [Paragraph] {
        let string = text.string
        let lines = string.split(omittingEmptySubsequences: false, whereSeparator: \.isLineBreak)
        return lines.map { line in
            var pieces: [(format: RunFormat, text: [String])] = []
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: string)
            text.enumerateAttributes(in: lineRange) { attributes, range, _ in
                // Slicing rounds an index inside a surrogate pair down, so a range that
                // splits a pair yields the whole scalar once and an empty piece.
                guard let bounds = Range(range, in: string) else { return }
                var piece = String(string[bounds])
                piece.removeAll(where: \.isObjectReplacement)
                guard !piece.isEmpty else { return }
                let format = RunFormat(attributes)
                if pieces.last?.format == format {
                    pieces[pieces.count - 1].text.append(piece)
                } else {
                    pieces.append((format, [piece]))
                }
            }
            return Paragraph(pieces.map { $0.format.run($0.text.joined()) })
        }
    }
}

/// Everything about a run except its text: the one mapping between `Run` and attributes.
struct RunFormat: Hashable, Sendable {
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
