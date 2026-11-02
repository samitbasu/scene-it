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

    @MainActor
    public func font(_ styles: Set<TextStyle>) -> NSFont {
        let traits = styles.reduce(into: baseTraits) { traits, style in
            traits.formUnion(style.fontTrait)
        }
        let size = pointSize
        let base = NSFont(name: Self.fontFamily, size: size) ?? .systemFont(ofSize: size)
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
    }

    /// The attributes of text in this role, for `typingAttributes` and paragraph breaks.
    @MainActor
    public var typingAttributes: [NSAttributedString.Key: Any] {
        RunFormat().attributes(in: self)
    }

    private var pointSize: CGFloat {
        switch self {
        case .title: 18
        case .body, .notes: 12
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
