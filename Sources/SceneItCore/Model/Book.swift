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
    /// Scenes deleted from the Boneyard, most recently deleted first (ADR 0031). The file keeps
    /// them, but the writer is never shown them: nothing that lists, searches, counts or
    /// exports scenes reads this, only what must see the whole file (`everyScene`). Internal,
    /// so the app can't show them.
    var deleted: [BookScene]
    /// What the parser found outside any scene and couldn't understand, kept verbatim until
    /// the writer deletes or repairs it.
    public var errors: [ErrorEntry]

    public init(
        title: String,
        scenes: [BookScene] = [],
        boneyard: [BookScene] = [],
        errors: [ErrorEntry] = []
    ) {
        self.init(title: title, scenes: scenes, boneyard: boneyard, deleted: [], errors: errors)
    }

    init(
        title: String,
        scenes: [BookScene] = [],
        boneyard: [BookScene] = [],
        deleted: [BookScene],
        errors: [ErrorEntry] = []
    ) {
        self.title = CharacterPolicy.admitted(title)
        self.scenes = scenes
        self.boneyard = boneyard
        self.deleted = deleted
        self.errors = errors
    }
}

extension Book {
    /// The scenes the writer can see, in file order: the story's, then the Boneyard's.
    public var visibleScenes: [BookScene] {
        FilePart.visible.flatMap { self[keyPath: $0.scenes] }
    }

    /// Where the scene with this id is among the scenes the writer can see. A deleted scene has
    /// no place there. Everything that finds a scene for the writer comes here.
    func visiblePlace(of id: SceneID?) -> (part: FilePart, index: Int)? {
        guard let id else { return nil }
        for part in FilePart.visible {
            if let index = self[keyPath: part.scenes].firstIndex(where: { $0.id == id }) {
                return (part, index)
            }
        }
        return nil
    }

    /// The scene with this id, in the story or the Boneyard: never a deleted one.
    public func scene(_ id: SceneID?) -> BookScene? {
        visiblePlace(of: id).map { self[keyPath: $0.part.scenes][$0.index] }
    }

    /// The book's scene lists in file order, the deleted one included.
    static var everySceneList: [WritableKeyPath<Book, [BookScene]>] { FilePart.allCases.map(\.scenes) }

    /// Every scene the file holds, in file order, the deleted ones included: for what must see
    /// the whole file (ids, error entries, the format), never for what the writer is shown.
    var everyScene: [BookScene] {
        scenes + boneyard + deleted
    }

    /// Every error entry, grouped in the Errors tab's order: the book's, then each story
    /// scene's, each Boneyard scene's and each deleted scene's (book format §5.4).
    public var errorEntries: [[ErrorEntry]] {
        [errors] + everyScene.map(\.errors)
    }

    /// Moves the scene with this id from `part` (the story or the Boneyard) to the top of the
    /// Deleted section (ADR 0031); returns where it was in `part`. `nil`, changing nothing, if
    /// `part` has no such scene or is the Deleted section itself.
    mutating func delete(_ id: SceneID, from part: FilePart) -> Int? {
        guard part != .deleted, let index = self[keyPath: part.scenes].firstIndex(where: { $0.id == id })
        else { return nil }
        deleted.insert(self[keyPath: part.scenes].remove(at: index), at: 0)
        return index
    }

    /// Undoes `delete(_:from:)`: moves the deleted scene with this id back into `part` at `index`
    /// (or its end). `false`, changing nothing, if there's no such deleted scene or `part` is the
    /// Deleted section itself.
    mutating func undelete(_ id: SceneID, to part: FilePart, at index: Int) -> Bool {
        guard part != .deleted, let from = deleted.firstIndex(where: { $0.id == id }) else { return false }
        let count = self[keyPath: part.scenes].count
        self[keyPath: part.scenes].insert(deleted.remove(at: from), at: min(index, count))
        return true
    }
}
