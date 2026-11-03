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

    public var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch self {
        case .title, .notes:
            break
        case .body:
            style.lineHeightMultiple = 2
            style.firstLineHeadIndent = 36
        }
        return style
    }

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
