/// Which version of the book a search unit comes from (PLAN §9.2).
public enum SearchVersion: Hashable, Sendable {
    /// The open book, unsaved text included.
    case working
    case filed(FiledCopyNumber)
}

/// Where a scene sits in its version: the Search sheet shows the number, or **B**.
public enum ScenePlacement: Hashable, Sendable {
    /// Numbered from 1.
    case story(number: Int)
    case boneyard
}

/// The part of a scene a unit's text is.
public enum SearchField: Hashable, Sendable {
    case title
    /// Paragraphs are numbered from 0, as in `BookScene.body`.
    case body(paragraph: Int)
    case notes(paragraph: Int)
    case comment(CommentID)
    /// The scene's tags, joined by `SearchUnit.tagSeparator`.
    case tags
}

/// The smallest thing search ranks: one paragraph of a title, body or notes, one comment, or a
/// scene's tag set.
public struct SearchUnit: Hashable, Sendable {
    public let version: SearchVersion
    public let scene: SceneID
    public let sceneTitle: String
    public let placement: ScenePlacement
    public let field: SearchField
    /// Admitted (`CharacterPolicy`), as model text is, so it is printable ASCII.
    public let text: String

    public init(
        version: SearchVersion, scene: SceneID, sceneTitle: String, placement: ScenePlacement,
        field: SearchField, text: String
    ) {
        self.version = version
        self.scene = scene
        self.sceneTitle = sceneTitle
        self.placement = placement
        self.field = field
        self.text = CharacterPolicy.admitted(text)
    }

    /// A line break ends a sentence, so a phrase can't run from one tag into the next.
    public static let tagSeparator = "\n"

    /// Every non-empty unit of `book`, in book order: the story's scenes, then the Boneyard's;
    /// in each, the title, the body, the notes, the comments, then the tags. A filed copy's
    /// units are its decoded book's, with `version: .filed(number)`.
    public static func units(of book: Book, version: SearchVersion) -> [SearchUnit] {
        let story = book.scenes.enumerated().flatMap { index, scene in
            units(of: scene, placement: .story(number: index + 1), version: version)
        }
        return story + book.boneyard.flatMap { units(of: $0, placement: .boneyard, version: version) }
    }

    private static func units(of scene: BookScene, placement: ScenePlacement, version: SearchVersion)
        -> [SearchUnit]
    {
        let fields: [(SearchField, String)] =
            [(.title, scene.title.text)]
            + scene.body.enumerated().map { (.body(paragraph: $0), $1.text) }
            + scene.notes.enumerated().map { (.notes(paragraph: $0), $1.text) }
            + scene.comments.map { (.comment($0.id), $0.text) }
            + [(.tags, scene.tags.joined(separator: tagSeparator))]
        return fields.filter { !$0.1.isEmpty }.map { field, text in
            SearchUnit(
                version: version, scene: scene.id, sceneTitle: scene.title.text, placement: placement,
                field: field, text: text)
        }
    }
}
