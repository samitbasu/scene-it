/// A scene's title: one line of plain text (decision 0015).
///
/// `book.md` writes it as the scene's `## ` heading; formatting typed into a heading by hand
/// is dropped on load, keeping the text. The type doesn't prevent a line break, but a book
/// whose title holds one fails save verification.
public struct SceneTitle: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var text: String

    public init(_ text: String) {
        self.text = text
    }

    public init(stringLiteral text: String) {
        self.init(text)
    }

    /// Each line break becomes a space, so pasted text stays on one line, and object
    /// replacement characters are removed.
    public init(pasted text: String) {
        self.init(String(text.filter { !$0.isObjectReplacement }.map { $0.isLineBreak ? " " : $0 }))
    }

    public var description: String { text }
}
