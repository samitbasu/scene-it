public enum TextStyle: String, CaseIterable, Hashable, Sendable {
    case bold, italic, strike
}

/// A stretch of text with uniform formatting.
///
/// In `book.json` each style is a `true` flag and `comments` is an id array, all omitted
/// when absent. In memory, absence is the empty set, so "`false`" and "`[]`" can't exist.
/// Decoding rejects them rather than normalizing, so the encoder's output is a fixed
/// point: encode → decode → encode is byte-identical. The one normalization is
/// `"color": "black"`, which decodes as no color (decision 0013).
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

extension Run: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case text, bold, italic, strike, color, highlight, comments

        init(_ style: TextStyle) {
            switch style {
            case .bold: self = .bold
            case .italic: self = .italic
            case .strike: self = .strike
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        styles = []
        for style in TextStyle.allCases {
            let key = CodingKeys(style)
            switch try container.decodeUnlessAbsent(Bool.self, forKey: key) {
            case true?: styles.insert(style)
            case false?: throw container.corrupted(key, "must be true when present; omit it instead of false")
            case nil: break
            }
        }
        color = try container.decodeUnlessAbsent(PaletteColor.self, forKey: .color).flatMap(TextColor.init)
        highlight = try container.decodeUnlessAbsent(HighlightColor.self, forKey: .highlight)
        let ids = try container.decodeUnlessAbsent([CommentID].self, forKey: .comments) ?? []
        comments = Set(ids)
        if container.contains(.comments) && ids.isEmpty {
            throw container.corrupted(.comments, "must not be empty when present; omit it instead")
        }
        if comments.count != ids.count {
            throw container.corrupted(.comments, "lists the same comment id more than once")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        for style in styles {
            try container.encode(true, forKey: CodingKeys(style))
        }
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(highlight, forKey: .highlight)
        if !comments.isEmpty {
            try container.encode(comments.sorted(), forKey: .comments)
        }
    }
}

/// A paragraph: an array of runs in `book.json`.
public struct Paragraph: Hashable, Sendable, Codable, ExpressibleByArrayLiteral {
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

    public init(from decoder: any Decoder) throws {
        runs = try decoder.singleValueContainer().decode([Run].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(runs)
    }
}
