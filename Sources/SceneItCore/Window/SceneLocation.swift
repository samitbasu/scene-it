/// Where the open scene is. The rail's Current scene badge, the breadcrumb and the status bar
/// all show it (PLAN §4), so they read this one value and can't disagree.
public enum SceneLocation: Hashable, Sendable {
    /// No scene is open: an empty book, or the open scene was deleted for good.
    case noScene
    /// In the story, numbered from 1.
    case story(number: Int, of: Int)
    case boneyard

    public init(of scene: SceneID?, in book: Book) {
        guard let scene else {
            self = .noScene
            return
        }
        if let index = book.scenes.firstIndex(where: { $0.id == scene }) {
            self = .story(number: index + 1, of: book.scenes.count)
        } else if book.boneyard.contains(where: { $0.id == scene }) {
            self = .boneyard
        } else {
            self = .noScene
        }
    }
}

/// The rail's Current scene icon (PLAN §4.2).
public enum CurrentSceneMark: Hashable, Sendable {
    /// Grayed out, with no badge.
    case unavailable
    case badge(String)

    public init(_ location: SceneLocation) {
        switch location {
        case .noScene: self = .unavailable
        case .story(let number, _): self = .badge(String(number))
        case .boneyard: self = .badge(WindowWording.boneyardBadge)
        }
    }
}

extension Book {
    /// The scene with this id, in the story or the Boneyard.
    public func scene(_ id: SceneID?) -> BookScene? {
        guard let id else { return nil }
        return scenes.first { $0.id == id } ?? boneyard.first { $0.id == id }
    }
}
