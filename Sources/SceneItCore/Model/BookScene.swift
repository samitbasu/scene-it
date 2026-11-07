/// A comment's anchor is the set of runs whose `comments` list its id, so it isn't stored
/// here. A comment no run mentions is *detached*: its text was deleted (PLAN §8.1).
public struct Comment: Identifiable, Hashable, Sendable {
    public var id: CommentID
    public var color: PaletteColor
    /// Text `CharacterPolicy` admits, which may hold line breaks; every assignment
    /// applies the policy.
    public var text: String {
        didSet { text = CharacterPolicy.admitted(text) }
    }
    public var created: Timestamp

    public init(id: CommentID, color: PaletteColor, text: String, created: Timestamp) {
        self.id = id
        self.color = color
        self.text = CharacterPolicy.admitted(text)
        self.created = created
    }
}

public struct BookScene: Identifiable, Hashable, Sendable {
    public var id: SceneID
    public var modified: Timestamp
    public var title: SceneTitle
    /// Stored without the leading `#`. Each is one line of text `CharacterPolicy` admits, and
    /// none is empty: every assignment applies `CharacterPolicy.admittedTags`.
    public var tags: [String] {
        didSet { tags = CharacterPolicy.admittedTags(tags) }
    }
    public var body: [Paragraph]
    /// Never carries a comment id: comments are on the manuscript only (ADR 0035). Every
    /// assignment takes any off.
    public var notes: [Paragraph] {
        didSet {
            if !Paragraph.commentIDs(in: notes).isEmpty { notes = notes.map(\.uncommented) }
        }
    }
    public var comments: [Comment]
    /// What the parser couldn't understand in this scene, kept verbatim. They travel with
    /// the scene to and from the Boneyard.
    public var errors: [ErrorEntry]

    public init(
        id: SceneID,
        modified: Timestamp,
        title: SceneTitle,
        tags: [String] = [],
        body: [Paragraph] = [],
        notes: [Paragraph] = [],
        comments: [Comment] = [],
        errors: [ErrorEntry] = []
    ) {
        self.id = id
        self.modified = modified
        self.title = title
        self.tags = CharacterPolicy.admittedTags(tags)
        self.body = body
        self.notes = notes.map(\.uncommented)
        self.comments = comments
        self.errors = errors
    }

    /// The scene's comment `id`, if it has it.
    public func comment(_ id: CommentID) -> Comment? {
        comments.first { $0.id == id }
    }

    /// Whether no run in the body carries the comment.
    public func isDetached(_ comment: CommentID) -> Bool {
        !Paragraph.commentIDs(in: body).contains(comment)
    }

}

/// A scene's two texts of formatted paragraphs: its body, on the page, and its notes, in the
/// Notes tab (PLAN §8.2). Each has its plain text (book format §3.6), which a comment's or a
/// mark's range addresses.
public enum TextPart: Hashable, Comparable, Sendable, CaseIterable {
    case body, notes

    public var paragraphs: WritableKeyPath<BookScene, [Paragraph]> {
        switch self {
        case .body: \.body
        case .notes: \.notes
        }
    }
}
