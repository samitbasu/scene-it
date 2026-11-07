/// The comments panel's cards for a scene (PLAN §8.1): its anchored comments in the order their
/// text starts on the page, then the detached ones, whose text is all gone, in the scene's order.
public struct CommentCards: Hashable, Sendable {
    public struct Card: Hashable, Sendable, Identifiable {
        public let comment: Comment
        /// The text the comment covers, its separate stretches joined by `CommentWording.quoteGap`
        /// and its line breaks as spaces; empty for a detached comment.
        public let quote: String

        public var id: CommentID { comment.id }
    }

    public let anchored: [Card]
    public let detached: [Card]

    /// The comments' ranges and quotes are `book.md`'s (`WrittenText`), and which are detached
    /// is `BookScene.isDetached`.
    public init(_ scene: BookScene) {
        let body = WrittenText(scene.body)
        let ranges = body.commentRanges()
        func quote(_ id: CommentID) -> String {
            (ranges[id] ?? []).map { body.text($0).replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: CommentWording.quoteGap)
        }
        let order = Dictionary(uniqueKeysWithValues: scene.comments.enumerated().map { ($1.id, $0) })
        func start(_ comment: Comment) -> (Int, Int) {
            (ranges[comment.id]?.first?.lowerBound ?? 0, order[comment.id] ?? 0)
        }
        anchored = scene.comments.filter { !scene.isDetached($0.id) }
            .sorted { start($0) < start($1) }
            .map { Card(comment: $0, quote: quote($0.id)) }
        detached = scene.comments.filter { scene.isDetached($0.id) }.map { Card(comment: $0, quote: "") }
    }

    private init(anchored: [Card], detached: [Card]) {
        self.anchored = anchored
        self.detached = detached
    }

    /// The cards `query` matches, in the same order.
    public func filtered(by query: CommentQuery) -> CommentCards {
        guard !query.isEmpty else { return self }
        return CommentCards(
            anchored: anchored.filter { query.matches($0.comment) },
            detached: detached.filter { query.matches($0.comment) })
    }

    public var isEmpty: Bool {
        anchored.isEmpty && detached.isEmpty
    }

    /// Every card, anchored first: the order they're shown in.
    public var all: [Card] {
        anchored + detached
    }
}
