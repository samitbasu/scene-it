/// The open scene and where it is. The rail's Current scene badge, the breadcrumb and the
/// status bar all show it (PLAN §4), so they read this one value and can't disagree.
public enum SceneLocation: Hashable, Sendable {
    /// No scene is open: an empty book, or the open scene was deleted for good.
    case noScene
    /// In the story, numbered from 1.
    case story(BookScene, number: Int, of: Int)
    case boneyard(BookScene)

    public init(of scene: SceneID?, in book: Book) {
        switch book.visiblePlace(of: scene) {
        case (.story, let index)?: self = .story(book.scenes[index], number: index + 1, of: book.scenes.count)
        case (.boneyard, let index)?: self = .boneyard(book.boneyard[index])
        case (.deleted, _)?, nil: self = .noScene
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

/// View → Previous Scene and Next Scene.
public enum SceneStep: Hashable, Sendable, CaseIterable {
    case previous, next
}

extension Book {
    /// The scene before or after `scene` in story order. Only the story is walked: from a
    /// Boneyard scene, or past either end, there's no step.
    public func scene(_ step: SceneStep, from scene: SceneID?) -> SceneID? {
        guard let index = scenes.firstIndex(where: { $0.id == scene }) else { return nil }
        let target =
            switch step {
            case .previous: index - 1
            case .next: index + 1
            }
        return scenes.indices.contains(target) ? scenes[target].id : nil
    }
}
