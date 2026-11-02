/// A comment's anchor is the set of runs whose `comments` list its id, so it isn't stored here.
public struct Comment: Identifiable, Hashable, Sendable, Encodable {
    public var id: CommentID
    public var color: TextColor
    public var text: String
    public var created: Timestamp

    public init(id: CommentID, color: TextColor, text: String, created: Timestamp) {
        self.id = id
        self.color = color
        self.text = text
        self.created = created
    }
}

extension Comment: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, color, text, created
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        id = try container.decode(CommentID.self, forKey: .id)
        color = try container.decode(TextColor.self, forKey: .color)
        text = try container.decode(String.self, forKey: .text)
        created = try container.decode(Timestamp.self, forKey: .created)
    }
}

public struct Scene: Identifiable, Hashable, Sendable, Encodable {
    public var id: SceneID
    public var modified: Timestamp
    /// Exactly one line: `BookValidator` rejects a line break in it.
    public var title: Paragraph
    /// Stored without the leading `#`.
    public var tags: [String]
    public var body: [Paragraph]
    public var notes: [Paragraph]
    public var comments: [Comment]

    public init(
        id: SceneID,
        modified: Timestamp,
        title: Paragraph,
        tags: [String] = [],
        body: [Paragraph] = [],
        notes: [Paragraph] = [],
        comments: [Comment] = []
    ) {
        self.id = id
        self.modified = modified
        self.title = title
        self.tags = tags
        self.body = body
        self.notes = notes
        self.comments = comments
    }
}

extension Scene: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, modified, title, tags, body, notes, comments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        id = try container.decode(SceneID.self, forKey: .id)
        modified = try container.decode(Timestamp.self, forKey: .modified)
        title = try container.decode(Paragraph.self, forKey: .title)
        tags = try container.decode([String].self, forKey: .tags)
        body = try container.decode([Paragraph].self, forKey: .body)
        notes = try container.decode([Paragraph].self, forKey: .notes)
        comments = try container.decode([Comment].self, forKey: .comments)
    }
}
