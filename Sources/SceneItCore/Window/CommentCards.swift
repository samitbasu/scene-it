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

    public init(_ scene: BookScene) {
        var pieces: [CommentID: [String]] = [:]
        var starts: [CommentID: Int] = [:]
        /// Where the last run each comment covers ended, to tell a continuing stretch from a new one.
        var ends: [CommentID: Int] = [:]
        var offset = 0
        for (index, paragraph) in scene.body.enumerated() {
            if index > 0 { offset += 1 }
            let paragraphStart = offset
            for run in paragraph.runs {
                for id in run.comments {
                    if starts[id] == nil { starts[id] = offset }
                    let end = ends[id]
                    // Across a line break, which carries no comment, the stretch goes on.
                    let joining: String? =
                        end == offset ? "" : end == paragraphStart - 1 && offset == paragraphStart ? " " : nil
                    if let joining, let last = pieces[id]?.popLast() {
                        pieces[id]?.append(last + joining + run.text)
                    } else {
                        pieces[id, default: []].append(run.text)
                    }
                    ends[id] = offset + run.text.utf16.count
                }
                offset += run.text.utf16.count
            }
        }
        let order = Dictionary(uniqueKeysWithValues: scene.comments.enumerated().map { ($1.id, $0) })
        anchored = scene.comments.filter { starts[$0.id] != nil }
            .sorted { (starts[$0.id]!, order[$0.id]!) < (starts[$1.id]!, order[$1.id]!) }
            .map {
                Card(comment: $0, quote: (pieces[$0.id] ?? []).joined(separator: CommentWording.quoteGap))
            }
        detached = scene.comments.filter { starts[$0.id] == nil }.map { Card(comment: $0, quote: "") }
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
