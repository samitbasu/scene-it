import Observation

/// The selected comment (PLAN §8.1): the card the comments panel shows selected, chosen there or
/// by clicking commented text on the page or in the notes. It belongs to a scene, so it means
/// nothing once another scene is open.
@MainActor @Observable
public final class CommentSelection {
    public struct Selected: Hashable, Sendable {
        public let scene: SceneID
        public let comment: CommentID
    }

    public private(set) var selected: Selected?

    public init() {}

    /// The selected comment, if it's `scene`'s.
    public func comment(in scene: SceneID) -> CommentID? {
        selected?.scene == scene ? selected?.comment : nil
    }

    public func select(_ comment: CommentID, in scene: SceneID) {
        selected = Selected(scene: scene, comment: comment)
    }

    public func deselect() {
        selected = nil
    }

    /// A click on text that `covering`, newest first, cover: selects the newest of them; or, when
    /// one of them is already selected, the next older one, and after the oldest the newest
    /// again, so clicking the same spot again cycles through them. Covered by none, it changes
    /// nothing.
    public func click(covering: [CommentID], in scene: SceneID) {
        guard let newest = covering.first else { return }
        guard let current = comment(in: scene), let index = covering.firstIndex(of: current) else {
            select(newest, in: scene)
            return
        }
        select(covering[(index + 1) % covering.count], in: scene)
    }
}
