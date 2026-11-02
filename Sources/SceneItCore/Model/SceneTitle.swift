/// A scene's title: one line of plain text (decision 0015).
///
/// `book.md` writes it as the scene's `## ` heading; formatting typed into a heading by hand
/// is dropped on load, keeping the text.
public struct SceneTitle: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// One line of text `CharacterPolicy` admits: every assignment applies the policy, and
    /// a line break becomes a space.
    public var text: String {
        didSet { text = CharacterPolicy.admittedLine(text) }
    }

    public init(_ text: String) {
        self.text = CharacterPolicy.admittedLine(text)
    }

    public init(stringLiteral text: String) {
        self.init(text)
    }

    /// As `init(_:)`, except that object replacement characters are removed rather than
    /// becoming `[?]`.
    public init(pasted text: String) {
        self.init(String(text.filter { !$0.isObjectReplacement }))
    }

    public var description: String { text }
}
