/// A whole book, as `book.md` holds it (docs/format/book-format.md).
public struct Book: Hashable, Sendable {
    /// Text `CharacterPolicy` admits; every assignment applies the policy.
    public var title: String {
        didSet { title = CharacterPolicy.admitted(title) }
    }
    /// Story order.
    public var scenes: [BookScene]
    /// Cut scenes, most recently cut first.
    public var boneyard: [BookScene]
    /// What the parser found outside any scene and couldn't understand, kept verbatim until
    /// the writer deletes or repairs it.
    public var errors: [ErrorEntry]

    public init(
        title: String,
        scenes: [BookScene] = [],
        boneyard: [BookScene] = [],
        errors: [ErrorEntry] = []
    ) {
        self.title = CharacterPolicy.admitted(title)
        self.scenes = scenes
        self.boneyard = boneyard
        self.errors = errors
    }
}

extension Book {
    /// The scene with this id, in the story or the Boneyard.
    public func scene(_ id: SceneID?) -> BookScene? {
        guard let id else { return nil }
        return scenes.first { $0.id == id } ?? boneyard.first { $0.id == id }
    }

    /// Every error entry, grouped in the Errors tab's order: the book's, then each story
    /// scene's, then each Boneyard scene's.
    public var errorEntries: [[ErrorEntry]] {
        [errors] + scenes.map(\.errors) + boneyard.map(\.errors)
    }
}
