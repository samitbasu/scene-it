/// Where in the story a scene goes when it's moved or restored (PLAN §7.2, §7.3): just before a
/// story scene, or at the end.
public enum StorySlot: Hashable, Sendable {
    case before(SceneID)
    case end
}

/// A change to where a scene is, from the Scenes sheet (PLAN §7.2, §7.3): one step on
/// `structureUndo`.
public enum SceneChange: Hashable, Sendable {
    /// A story scene to another place in the story.
    case move(SceneID, to: StorySlot)
    /// A story scene to the front of the Boneyard.
    case cut(SceneID)
    /// A Boneyard scene into the story.
    case restore(SceneID, to: StorySlot)

    public var scene: SceneID {
        switch self {
        case .move(let scene, _), .cut(let scene), .restore(let scene, _): scene
        }
    }
}

/// A place among the scenes the writer can see: a part of the book, and an index in it.
struct ScenePlace: Hashable, Sendable {
    let part: FilePart
    let index: Int
}

extension Book {
    /// Where `change` puts its scene, if it applies: the move's scene must be in the story, the
    /// cut's in the story, and the restore's in the Boneyard.
    func destination(of change: SceneChange) -> ScenePlace? {
        switch change {
        case .move(let scene, let slot):
            guard scenes.contains(where: { $0.id == scene }) else { return nil }
            return landing(of: scene, in: slot).map { ScenePlace(part: .story, index: $0) }
        case .cut(let scene):
            guard scenes.contains(where: { $0.id == scene }) else { return nil }
            return ScenePlace(part: .boneyard, index: 0)
        case .restore(let scene, let slot):
            guard boneyard.contains(where: { $0.id == scene }) else { return nil }
            return landing(of: scene, in: slot).map { ScenePlace(part: .story, index: $0) }
        }
    }

    /// The index in the story that a scene put in `slot` lands at, counted with `moving` already
    /// out of the story. `.before(moving)` leaves it where it is. `nil` if the slot is before a
    /// scene that isn't in the story.
    func landing(of moving: SceneID, in slot: StorySlot) -> Int? {
        let others = scenes.filter { $0.id != moving }
        switch slot {
        case .end:
            return others.count
        case .before(let scene) where scene == moving:
            return scenes.firstIndex { $0.id == moving }
        case .before(let scene):
            return others.firstIndex { $0.id == scene }
        }
    }

    /// The slot that puts story scene `moving` where story scene `target` is now: just after it
    /// when it's later in the story, just before it when it's earlier. `nil` if either isn't in
    /// the story, or they're the same scene.
    public func slot(takingThePlaceOf target: SceneID, from moving: SceneID) -> StorySlot? {
        guard let from = scenes.firstIndex(where: { $0.id == moving }),
            let to = scenes.firstIndex(where: { $0.id == target }), from != to
        else { return nil }
        if to < from { return .before(target) }
        return scenes.indices.contains(to + 1) ? .before(scenes[to + 1].id) : .end
    }

    /// Moves the scene with this id, in the story or the Boneyard, to `place`: its index there
    /// counted once the scene is out of where it was, and held to the part's ends. Returns where
    /// it was, which moves it back. `nil`, changing nothing, if the writer can't see such a
    /// scene, `place` is in the Deleted section (that's `delete(_:from:)`), or the scene is
    /// already there.
    mutating func relocate(_ id: SceneID, to place: ScenePlace) -> ScenePlace? {
        guard place.part != .deleted, let (part, index) = visiblePlace(of: id) else { return nil }
        let others = self[keyPath: place.part.scenes].count - (part == place.part ? 1 : 0)
        let destination = min(max(place.index, 0), others)
        guard part != place.part || destination != index else { return nil }
        let scene = self[keyPath: part.scenes].remove(at: index)
        self[keyPath: place.part.scenes].insert(scene, at: destination)
        return ScenePlace(part: part, index: index)
    }
}
