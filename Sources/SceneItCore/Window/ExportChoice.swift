/// Export as SceneIt…'s scene chooser (ADR 0029): the book's story scenes, in story order, all ticked to
/// begin with. A click toggles one scene; a Shift-click sets every scene from the last one
/// clicked to this one as this one becomes, as Mail and Finder do with checkboxes.
public struct ExportChoice: Hashable, Sendable {
    public struct Row: Identifiable, Hashable, Sendable {
        public let id: SceneID
        /// The scene's place in the story, from 1.
        public let number: Int
        public let name: String
    }

    public let rows: [Row]
    public private(set) var ticked: Set<SceneID>
    /// Whatever is ticked, the export leaves out text of the book's own that Scene It couldn't read.
    public let leavesOutBookText: Bool
    /// The scenes whose export would leave out text Scene It couldn't read.
    private let holdingUnreadableText: Set<SceneID>
    /// Where a Shift-click's range starts: the last scene clicked.
    private var anchor: SceneID?

    public init(book: Book) {
        rows = book.scenes.enumerated().map { index, scene in
            Row(id: scene.id, number: index + 1, name: WindowWording.sceneName(scene))
        }
        ticked = Set(rows.map(\.id))
        holdingUnreadableText = Set(book.scenes.filter(ReviewCopy.leavesOutUnreadableText(of:)).map(\.id))
        leavesOutBookText = ReviewCopy.leavesOutUnreadableText(ofBookItself: book)
    }

    public func isTicked(_ id: SceneID) -> Bool {
        ticked.contains(id)
    }

    public mutating func click(_ id: SceneID, _ kind: ChoiceClick) {
        guard let target = rows.firstIndex(where: { $0.id == id }) else { return }
        let tick = !isTicked(id)
        let range: ClosedRange<Int> =
            switch (kind, anchor.flatMap { anchor in rows.firstIndex { $0.id == anchor } }) {
            case (.extendingRange, let start?): min(start, target)...max(start, target)
            default: target...target
            }
        for row in rows[range] {
            if tick { ticked.insert(row.id) } else { ticked.remove(row.id) }
        }
        anchor = id
    }

    public mutating func tickAll() {
        ticked = Set(rows.map(\.id))
    }

    public mutating func untickAll() {
        ticked = []
    }

    /// Export can go ahead: at least one scene is ticked.
    public var canExport: Bool {
        !ticked.isEmpty
    }

    /// Some ticked scene holds text Scene It couldn't read, which the export leaves out.
    public var leavesOutTickedScenesText: Bool {
        !ticked.isDisjoint(with: holdingUnreadableText)
    }

    public var allTicked: Bool {
        ticked.count == rows.count
    }
}

/// How a scene's checkbox was clicked.
public enum ChoiceClick: Hashable, Sendable {
    case single
    /// With Shift held.
    case extendingRange
}
