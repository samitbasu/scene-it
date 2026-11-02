/// The open scene and where it is. The rail's Current scene badge, the breadcrumb and the
/// status bar all show it (PLAN §4), so they read this one value and can't disagree.
public enum SceneLocation: Hashable, Sendable {
    /// No scene is open: an empty book, or the open scene was deleted for good.
    case noScene
    /// In the story, numbered from 1.
    case story(BookScene, number: Int, of: Int)
    case boneyard(BookScene)

    public init(of scene: SceneID?, in book: Book) {
        if let scene, let index = book.scenes.firstIndex(where: { $0.id == scene }) {
            self = .story(book.scenes[index], number: index + 1, of: book.scenes.count)
        } else if let scene, let cut = book.boneyard.first(where: { $0.id == scene }) {
            self = .boneyard(cut)
        } else {
            self = .noScene
        }
    }

    public var scene: BookScene? {
        switch self {
        case .noScene: nil
        case .story(let scene, _, _), .boneyard(let scene): scene
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
        case .story(_, let number, _): self = .badge(String(number))
        case .boneyard: self = .badge(WindowWording.boneyardBadge)
        }
    }
}
