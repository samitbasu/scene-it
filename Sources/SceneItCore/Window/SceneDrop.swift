/// What's being dragged in the Scenes sheet: a story card, or a Boneyard tile.
public enum SceneDrag: Hashable, Sendable {
    case card(SceneID)
    case tile(SceneID)
}

/// Where a drag in the Scenes sheet can be dropped.
public enum DropZone: Hashable, Sendable {
    /// A story card: what's dropped goes just before it.
    case card(SceneID)
    /// The slot that shows where it will land.
    case slot
    /// The dashed + New scene tile after the last card: the end of the story.
    case end
    /// The Boneyard tray, for a card: it's cut.
    case tray
}

/// A drag in the Scenes sheet from start to drop: which zones the pointer is in, and so where
/// the slot shows (PLAN §7.3's "Restore here") and whether the tray is lit. The slot stays where
/// the last card or the end tile put it while the pointer is over any grid zone, the slot
/// included, so it doesn't vanish as it pushes the card it stands before out from under the
/// pointer.
public struct SceneDropState: Hashable, Sendable {
    public private(set) var drag: SceneDrag?
    private var inside: Set<DropZone> = []
    private var lastSlot: StorySlot?

    public init() {}

    public mutating func begin(_ drag: SceneDrag) {
        self = SceneDropState()
        self.drag = drag
    }

    /// Whether a drop on `zone` would do something: a card goes anywhere, a tile only into the
    /// grid.
    public func accepts(_ zone: DropZone) -> Bool {
        switch (drag, zone) {
        case (nil, _), (.tile, .tray): false
        case (.card, _), (.tile, _): true
        }
    }

    public mutating func enter(_ zone: DropZone) {
        guard accepts(zone) else { return }
        inside.insert(zone)
        if let slot = Self.slot(of: zone) { lastSlot = slot }
    }

    public mutating func exit(_ zone: DropZone) {
        inside.remove(zone)
    }

    /// Where the slot shows, while the pointer is over the grid.
    public var slot: StorySlot? {
        inside.contains { $0 != .tray } ? lastSlot : nil
    }

    public var isOverTray: Bool {
        inside.contains(.tray)
    }

    /// The drop on `zone`: what it changes, if anything. The drag is over either way.
    public mutating func drop(on zone: DropZone) -> SceneChange? {
        defer { self = SceneDropState() }
        guard accepts(zone), let drag else { return nil }
        let slot = Self.slot(of: zone) ?? lastSlot
        switch (drag, zone) {
        case (.card(let scene), .tray): return .cut(scene)
        case (.card(let scene), _): return slot.map { .move(scene, to: $0) }
        case (.tile(let scene), _): return slot.map { .restore(scene, to: $0) }
        }
    }

    /// Ends a drag that wasn't dropped here.
    public mutating func end() {
        self = SceneDropState()
    }

    private static func slot(of zone: DropZone) -> StorySlot? {
        switch zone {
        case .card(let scene): .before(scene)
        case .end: .end
        case .slot, .tray: nil
        }
    }
}

/// A step of the arrow keys in the Scenes sheet's grid.
public enum GridStep: Hashable, Sendable, CaseIterable {
    case left, right, up, down
}

/// The cards the Scenes sheet's grid shows, in order, as laid out in `columns` columns: where
/// the arrow keys go from a card.
public struct CardGrid: Hashable, Sendable {
    public let cards: [SceneID]
    public let columns: Int

    public init(cards: [SceneID], columns: Int) {
        self.cards = cards
        self.columns = max(1, columns)
    }

    /// The card `step` goes to from `card`. Left and right follow the story, from row to row;
    /// up and down go a row, and down from a row above the last stops at the last card. `nil`
    /// past either end, or from a card the grid doesn't show.
    public func neighbor(of card: SceneID, _ step: GridStep) -> SceneID? {
        guard let index = cards.firstIndex(of: card) else { return nil }
        let target: Int
        switch step {
        case .left: target = index - 1
        case .right: target = index + 1
        case .up: target = index - columns
        case .down:
            guard index / columns < (cards.count - 1) / columns else { return nil }
            target = min(index + columns, cards.count - 1)
        }
        return cards.indices.contains(target) ? cards[target] : nil
    }

    /// The card the keys start from when none has the focus: the open scene's, if the grid
    /// shows it, or the first.
    public func start(at open: SceneID?) -> SceneID? {
        if let open, cards.contains(open) { return open }
        return cards.first
    }
}
