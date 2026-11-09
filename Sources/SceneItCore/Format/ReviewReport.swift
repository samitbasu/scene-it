/// What Copy Review and Save Review… put out (review format §5): built once from a review, then
/// written as HTML, as plain text and as a standalone page, so the three can't disagree. Its text
/// is smartened (§5.3); it holds no manuscript body text but the paragraphs its comments quote.
public struct ReviewReport: Hashable, Sendable {
    /// The copy's book title.
    public let title: String
    /// The day Copy Review or Save Review… was chosen.
    public let day: CalendarDay
    /// The review's general notes, a paragraph each.
    public let notes: [ReportText]
    /// The scenes with a comment or a note, in story order.
    public let scenes: [Scene]

    public struct Scene: Hashable, Sendable {
        public let id: SceneID
        public let title: String
        public let items: [Item]
        public let notes: [ReportText]
    }

    /// A comment, as an item to tick off.
    public struct Item: Hashable, Sendable {
        public let key: ItemKey
        /// `nil` for a comment on the scene as a whole (a detached comment).
        public let quote: Quote?
        /// The comment's text; a line break in it is `\n`. Can be empty.
        public let comment: String
    }

    /// The paragraph a comment's passage is in, in three pieces (review format §5.2). A paragraph
    /// break inside it is shown as ` ¶ `.
    public struct Quote: Hashable, Sendable {
        public let before: ReportText
        public let passage: ReportText
        public let after: ReportText
    }

    /// An item's checkbox key on the standalone page (review format §7.2), `<scene id>/<comment id>`:
    /// unique in the review, and the same each time the review is saved.
    public struct ItemKey: Hashable, Sendable, CustomStringConvertible {
        public let scene: SceneID
        public let comment: CommentID

        public var description: String { "\(scene)/\(comment)" }
    }

    public init(_ review: Review, on day: CalendarDay) {
        title = Typography.smartened(review.book.title)
        self.day = day
        notes = review.notes.map(ReportText.init(paragraph:))
        scenes = review.book.scenes.filter(Self.includes).map(Self.scene)
    }

    /// Whether it has nothing to put out: no general notes, and no scene with a comment or a note.
    public var isEmpty: Bool {
        notes.isEmpty && scenes.isEmpty
    }

    /// Every item, in order.
    public var items: [Item] {
        scenes.flatMap(\.items)
    }

    static func includes(_ scene: BookScene) -> Bool {
        !scene.comments.isEmpty || !scene.notes.isEmpty
    }

    private static func scene(_ scene: BookScene) -> Scene {
        let body = StyledSource(scene.body)
        let hulls = body.hulls
        let anchored = scene.comments.enumerated()
            .compactMap { order, comment in hulls[comment.id].map { (comment, $0, order) } }
            .sorted { ($0.1.lowerBound, $0.1.upperBound, $0.2) < ($1.1.lowerBound, $1.1.upperBound, $1.2) }
            .map { comment, hull, _ in item(comment, in: scene, quoting: body.quote(hull)) }
        let detached = scene.comments.filter { hulls[$0.id] == nil }.map { item($0, in: scene, quoting: nil) }
        let title =
            scene.title.text.isEmpty
            ? ReviewOutputWording.untitledScene : Typography.smartened(scene.title.text)
        return Scene(
            id: scene.id, title: title, items: anchored + detached,
            notes: scene.notes.map(ReportText.init(paragraph:)))
    }

    private static func item(_ comment: Comment, in scene: BookScene, quoting quote: Quote?) -> Item {
        Item(
            key: ItemKey(scene: scene.id, comment: comment.id), quote: quote,
            comment: Typography.smartened(comment.text))
    }
}

extension Review {
    /// Whether Copy Review has anything to put out (review format §5.1).
    public var hasReport: Bool {
        !notes.isEmpty || book.scenes.contains(where: ReviewReport.includes)
    }
}

/// A run of output text in one style.
public struct ReportRun: Hashable, Sendable {
    public let text: String
    public let styles: Set<TextStyle>
}

/// Smartened text in maximal runs of one style. Empty for an empty paragraph.
public struct ReportText: Hashable, Sendable {
    public let runs: [ReportRun]

    /// The text without its styles.
    public var plain: String {
        runs.map(\.text).joined()
    }

    init(runs: [ReportRun]) {
        self.runs = runs
    }

    /// A notes paragraph, smartened as one unit.
    init(paragraph: Paragraph) {
        let source = StyledSource([paragraph])
        self = source.text(0..<source.count, in: SmartUnit(source.string(0..<source.count)), from: 0)
    }
}

/// A text of paragraphs as one run of characters, `\n` between paragraphs, each character with its
/// styles: a scene body's plain text (book format §3.6), which a comment's passage is a range of.
private struct StyledSource {
    private var scalars: [Unicode.Scalar] = []
    private var styles: [Set<TextStyle>] = []
    /// Each comment's hull, `[s, e)` (review format §5.2): from the first character it covers to
    /// the last. A comment never covers a `\n`.
    private(set) var hulls: [CommentID: Range<Int>] = [:]

    static let paragraphBreak: Unicode.Scalar = "\n"
    static let shownBreak = " \u{00B6} "

    init(_ paragraphs: [Paragraph]) {
        for (number, paragraph) in paragraphs.enumerated() {
            if number > 0 {
                scalars.append(Self.paragraphBreak)
                styles.append([])
            }
            for run in paragraph.runs {
                let start = scalars.count
                scalars += run.text.unicodeScalars
                styles += Array(repeating: run.styles, count: scalars.count - start)
                for id in run.comments {
                    let covered =
                        hulls[id].map { min($0.lowerBound, start)..<scalars.count } ?? start..<scalars.count
                    hulls[id] = covered
                }
            }
        }
    }

    var count: Int { scalars.count }

    func string(_ range: Range<Int>) -> String {
        var string = ""
        string.unicodeScalars.append(contentsOf: scalars[range])
        return string
    }

    /// The paragraphs holding `passage`, its smartened text in three pieces.
    func quote(_ passage: Range<Int>) -> ReviewReport.Quote {
        let start = scalars[..<passage.lowerBound].lastIndex(of: Self.paragraphBreak).map { $0 + 1 } ?? 0
        let end = scalars[passage.upperBound...].firstIndex(of: Self.paragraphBreak) ?? scalars.count
        let unit = SmartUnit(string(start..<end))
        return ReviewReport.Quote(
            before: text(start..<passage.lowerBound, in: unit, from: start),
            passage: text(passage, in: unit, from: start),
            after: text(passage.upperBound..<end, in: unit, from: start))
    }

    /// `range` in maximal runs of one style, smartened as part of `unit`, which starts at `unitStart`.
    func text(_ range: Range<Int>, in unit: SmartUnit, from unitStart: Int) -> ReportText {
        var runs: [ReportRun] = []
        var start = range.lowerBound
        while start < range.upperBound {
            if scalars[start] == Self.paragraphBreak {
                runs.append(ReportRun(text: Self.shownBreak, styles: []))
                start += 1
                continue
            }
            var end = start + 1
            while end < range.upperBound, scalars[end] != Self.paragraphBreak, styles[end] == styles[start] {
                end += 1
            }
            runs.append(
                ReportRun(text: unit.piece(start - unitStart..<end - unitStart), styles: styles[start]))
            start = end
        }
        return ReportText(runs: runs)
    }
}
