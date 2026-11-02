/// Whose error entries: the book's own (found outside any scene) or a scene's.
public enum ErrorOwner: Hashable, Sendable {
    case book
    case scene(SceneID)
}

/// One error entry, as the Errors tab lists it. `entry` is what the row showed, so an
/// operation on a row the book has since changed under is refused rather than applied to
/// another entry.
public struct ErrorRef: Hashable, Sendable {
    public let owner: ErrorOwner
    public let index: Int
    public let entry: ErrorEntry

    public init(owner: ErrorOwner, index: Int, entry: ErrorEntry) {
        self.owner = owner
        self.index = index
        self.entry = entry
    }
}

/// One owner's entries, in model order.
public struct ErrorGroup: Hashable, Sendable {
    public let owner: ErrorOwner
    public let refs: [ErrorRef]
}

/// The state of one owner of error entries, which an operation on an entry replaces as a
/// whole, so undoing it restores exactly what was there.
public enum BookPart: Hashable, Sendable {
    /// What the book holds outside its scenes.
    case header(title: String, errors: [ErrorEntry])
    case scene(BookScene)
}

extension Book {
    /// The Errors tab's groups (book format §5.4): the book's, then each story scene's, then
    /// each Boneyard scene's, leaving out owners with no entries.
    public var errorGroups: [ErrorGroup] {
        // TODO(#32): a File Cabinet group for `Archive/index.md`'s entries (book format §10
        // Q12), once the open book carries its archive index.
        let owners = [ErrorOwner.book] + (scenes + boneyard).map { .scene($0.id) }
        return owners.compactMap { owner in
            guard let entries = errors(of: owner), !entries.isEmpty else { return nil }
            return ErrorGroup(
                owner: owner,
                refs: entries.enumerated().map { ErrorRef(owner: owner, index: $0.offset, entry: $0.element) }
            )
        }
    }

    public var errorCount: Int {
        errorEntries.reduce(0) { $0 + $1.count }
    }

    /// `nil` for a scene the book doesn't have.
    public func errors(of owner: ErrorOwner) -> [ErrorEntry]? {
        switch owner {
        case .book: errors
        case .scene(let id): scene(id)?.errors
        }
    }

    /// Whether `ref` still names the entry it was made for.
    public func holds(_ ref: ErrorRef) -> Bool {
        guard let entries = errors(of: ref.owner), entries.indices.contains(ref.index) else { return false }
        return entries[ref.index] == ref.entry
    }

    public func part(_ owner: ErrorOwner) -> BookPart? {
        switch owner {
        case .book: .header(title: title, errors: errors)
        case .scene(let id): scene(id).map(BookPart.scene)
        }
    }

    /// Puts `part` in place of `owner`'s; a scene keeps its place in the story or the
    /// Boneyard, even if `part` gives it a new id. `false` if the book has no such owner.
    @discardableResult
    public mutating func replace(_ owner: ErrorOwner, with part: BookPart) -> Bool {
        switch (owner, part) {
        case (.book, .header(let title, let errors)):
            self.title = title
            self.errors = errors
            return true
        case (.scene(let id), .scene(let scene)):
            for list in [\Book.scenes, \Book.boneyard] {
                if let index = self[keyPath: list].firstIndex(where: { $0.id == id }) {
                    self[keyPath: list][index] = scene
                    return true
                }
            }
            return false
        case (.book, .scene), (.scene, .header):
            return false
        }
    }
}

extension BookPart {
    /// Whose part this is.
    public var owner: ErrorOwner {
        switch self {
        case .header: .book
        case .scene(let scene): .scene(scene.id)
        }
    }

    public var errors: [ErrorEntry] {
        switch self {
        case .header(_, let errors): errors
        case .scene(let scene): scene.errors
        }
    }

    /// The same part with `errors` in place of its own.
    func with(errors: [ErrorEntry]) -> BookPart {
        switch self {
        case .header(let title, _):
            return .header(title: title, errors: errors)
        case .scene(var scene):
            scene.errors = errors
            return .scene(scene)
        }
    }
}
