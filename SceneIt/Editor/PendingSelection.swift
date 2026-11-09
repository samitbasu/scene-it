import Foundation
import SceneItCore

/// A selection waiting for its scene to be shown: a search result being opened (PLAN §9.1).
/// The page, the notes and the title each hold one. The first time the view is next updated,
/// it takes the selection if it now shows that scene, or drops it if not, so a selection can't
/// linger and land later in some other showing of the scene.
struct PendingSelection {
    private var pending: (scene: SceneID, range: NSRange)?

    mutating func set(_ range: NSRange, in scene: SceneID) {
        pending = (scene, range)
    }

    /// The selection, if it's for `scene`; either way it's gone afterwards.
    mutating func take(showing scene: SceneID?) -> NSRange? {
        defer { pending = nil }
        guard let pending, pending.scene == scene else { return nil }
        return pending.range
    }
}
