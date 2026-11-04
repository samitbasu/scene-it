import AppKit

/// How a paragraph is displayed (PLAN §6.1, §8.2). Display only: none of this is saved.
public enum ParagraphRole: Hashable, Sendable, CaseIterable {
    /// The 18 pt bold heading that print and export put above a scene, built from its
    /// `SceneTitle`. The editors never use it: the title is edited in a plain field
    /// (decision 0015).
    case title
    case body, notes

    public static let fontFamily = "Times New Roman"

    /// Traits every run in the role has, whatever its styles.
    public var baseTraits: NSFontDescriptor.SymbolicTraits {
        switch self {
        case .title: .bold
        case .body, .notes: []
        }
    }

    /// The style of a paragraph with text in this role.
    public var paragraphStyle: NSParagraphStyle {
        paragraphStyle(for: .text)
    }

    public func paragraphStyle(for content: ParagraphContent) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch (self, content) {
        case (.title, _):
            break
        case (.notes, _):
            style.paragraphSpacing = Self.notesParagraphGap
        case (.body, .text):
            style.lineSpacing = Self.doubleSpacingGap
            style.firstLineHeadIndent = 36
        case (.body, .empty):
            // TextKit lays an empty line out with its line spacing inside it, which makes the
            // cursor there double height; spacing before it puts the line where typed text goes.
            style.paragraphSpacingBefore = Self.doubleSpacingGap
            style.firstLineHeadIndent = 36
        case (.body, .emptyEnd):
            // The line above already has its spacing below it.
            style.firstLineHeadIndent = 36
        }
        return style
    }

    /// Gives each paragraph of `text` that `range` touches the style for what it holds.
    public func styleParagraphs(of text: NSMutableAttributedString, around range: NSRange) {
        let string = text.string as NSString
        string.enumerateSubstrings(
            in: string.paragraphRange(for: range), options: [.byParagraphs, .substringNotRequired]
        ) {
            _, content, paragraph, _ in
            guard paragraph.length > 0 else { return }
            let style = paragraphStyle(for: content.length == 0 ? .empty : .text)
            var styled = true
            text.enumerateAttribute(.paragraphStyle, in: paragraph) { value, _, stop in
                if (value as? NSParagraphStyle) != style {
                    styled = false
                    stop.pointee = true
                }
            }
            if !styled { text.addAttribute(.paragraphStyle, value: style, range: paragraph) }
        }
    }

    /// What double spacing adds below each line of the body (ADR 0034): as much as TextKit adds
    /// when it lays a line out twice as tall (`lineHeightMultiple = 2`), which puts the space
    /// above the letters instead, so the cursor and the selection were twice the text's height.
    public static let doubleSpacingGap: CGFloat = {
        let font = textTypeface[[]]
        let doubled = NSMutableParagraphStyle()
        doubled.lineHeightMultiple = 2
        return TextKitLine.height(of: font, in: doubled) - TextKitLine.height(of: font, in: .default)
    }()

    /// Between the notes' paragraphs, which are otherwise single-spaced (the owner's pick, #19).
    private static let notesParagraphGap: CGFloat = 6

    public func font(_ styles: Set<TextStyle>) -> NSFont {
        let traits = styles.reduce(into: baseTraits) { traits, style in
            traits.formUnion(style.fontTrait)
        }
        return typeface[traits]
    }

    /// The attributes of text in this role, for `typingAttributes` and paragraph breaks.
    public var typingAttributes: [NSAttributedString.Key: Any] {
        RunFormat().attributes(in: self)
    }

    /// What text typed after text with `attributes` gets: its styles, color and highlight,
    /// shown in this role, and never its comments, so typing at the edge of a commented span
    /// doesn't extend the comment (PLAN §8.1).
    public func typingAttributes(continuing attributes: [NSAttributedString.Key: Any])
        -> [NSAttributedString.Key: Any]
    {
        var format = RunFormat(attributes)
        format.comments = []
        return format.attributes(in: self)
    }

    /// `attributes` as the codec would render them in this role: whatever a `Run` holds
    /// (styles, color, highlight, comments) kept, everything else the role's own.
    public func attributes(normalizing attributes: [NSAttributedString.Key: Any])
        -> [NSAttributedString.Key: Any]
    {
        RunFormat(attributes).attributes(in: self)
    }

    /// Each looked up once, because a lookup is a synchronous request to the font server, and
    /// several at once from different threads can wait for its replies forever (#77).
    private static let titleTypeface = Typeface(size: 18)
    private static let textTypeface = Typeface(size: 12)

    private var typeface: Typeface {
        switch self {
        case .title: Self.titleTypeface
        case .body, .notes: Self.textTypeface
        }
    }
}

/// What a paragraph holds, which decides where its double spacing goes (ADR 0034).
public enum ParagraphContent: Sendable {
    case text
    /// An empty paragraph: only its paragraph break.
    case empty
    /// The empty paragraph at the very end, after the final break or in empty text, which has
    /// no character of its own: TextKit lays it out in the typing attributes.
    case emptyEnd

    /// What the paragraph holding `location` holds.
    public init(ofParagraphAt location: Int, in string: NSString) {
        let paragraph = string.paragraphRange(for: NSRange(location: min(location, string.length), length: 0))
        if paragraph.length == 0 {
            self = .emptyEnd
            return
        }
        var end = paragraph.upperBound
        while end > paragraph.location,
            Character(String(utf16CodeUnits: [string.character(at: end - 1)], count: 1)).isLineBreak
        {
            end -= 1
        }
        self = end == paragraph.location ? .empty : .text
    }
}

extension TextPart {
    /// How the part's paragraphs are displayed.
    public var role: ParagraphRole {
        switch self {
        case .body: .body
        case .notes: .notes
        }
    }
}

/// Times New Roman's four faces at one size. Without Times New Roman, the system font's,
/// for as long as the process runs.
///
/// `@unchecked` because `NSFont` isn't marked `Sendable`, but it's immutable and toll-free
/// bridged to `CTFont`, whose header says all of its functions are thread safe.
private struct Typeface: @unchecked Sendable {
    private let regular, bold, italic, boldItalic: NSFont

    init(size: CGFloat) {
        let base: NSFont
        if let font = NSFont(name: ParagraphRole.fontFamily, size: size) {
            base = font
        } else {
            Log.editor.error("Times New Roman is missing; using the system font", ["size": .count(Int(size))])
            base = .systemFont(ofSize: size)
        }
        func face(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
            NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
        }
        regular = face([])
        bold = face(.bold)
        italic = face(.italic)
        boldItalic = face([.bold, .italic])
    }

    /// The face with `traits`' bold and italic; no other trait has a face of its own.
    subscript(traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        switch (traits.contains(.bold), traits.contains(.italic)) {
        case (false, false): regular
        case (true, false): bold
        case (false, true): italic
        case (true, true): boldItalic
        }
    }
}

extension TextStyle {
    /// Empty for strike, which is `.strikethroughStyle` rather than a font trait.
    var fontTrait: NSFontDescriptor.SymbolicTraits {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .strike: []
        }
    }

    /// The styles `font`'s traits express, whatever its family.
    static func styles(of font: NSFont) -> Set<TextStyle> {
        let traits = font.fontDescriptor.symbolicTraits
        return Set(allCases.filter { !$0.fontTrait.isEmpty && traits.contains($0.fontTrait) })
    }
}
