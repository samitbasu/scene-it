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
    /// Stored without the leading `#`. Each is text `CharacterPolicy` admits, and none is
    /// empty: every assignment applies the policy and drops empty tags.
    public var tags: [String] {
        didSet { tags = Self.admitted(tags) }
    }
    public var body: [Paragraph]
    public var notes: [Paragraph]
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
        self.tags = Self.admitted(tags)
        self.body = body
        self.notes = notes
        self.comments = comments
        self.errors = errors
    }

    private static func admitted(_ tags: [String]) -> [String] {
        tags.map(CharacterPolicy.admitted).filter { !$0.isEmpty }
    }

    /// Whether no run in the body or the notes carries the comment.
    public func isDetached(_ comment: CommentID) -> Bool {
        !Paragraph.commentIDs(in: body + notes).contains(comment)
    }
}
