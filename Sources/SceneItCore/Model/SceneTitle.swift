/// A scene's title: one line of plain text (decision 0015).
///
/// `book.json` keeps PLAN §5.2's shape, a paragraph of runs: `[{"text": "…"}]`, or `[]`
/// when empty. Decoding a formatted title keeps its text and drops the attributes,
/// including comment ids, so its next save writes a single plain run. `BookValidator`
/// rejects a line break, since the type doesn't prevent one.
public struct SceneTitle: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var text: String

    public init(_ text: String) {
        self.text = text
    }

    public init(stringLiteral text: String) {
        self.init(text)
    }

    /// Each line or paragraph separator becomes a space, so pasted text stays on one line.
    public init(pasted text: String) {
        self.init(String(text.map { $0.isNewline ? " " : $0 }))
    }

    public var description: String { text }
}

extension SceneTitle: Codable {
    public init(from decoder: any Decoder) throws {
        text = try Paragraph(from: decoder).text
    }

    public func encode(to encoder: any Encoder) throws {
        try Paragraph(text.isEmpty ? [] : [Run(text)]).encode(to: encoder)
    }
}
