import Foundation

/// What Scene It puts on the pasteboard, beside plain text and RTF, when the writer copies
/// from a page (decision 0017): the copied lines with all their formatting and comment ids,
/// the comments they mention, and the scene they came from.
///
/// It travels as a one-scene `book.md`, so it's written and read by the book format itself,
/// with its save verification and its parser that never fails.
public struct PageClip: Hashable, Sendable {
    public static let pasteboardType = "com.samitbasu.sceneit.page-clip"

    public let scene: SceneID
    /// One paragraph per copied line, so copying across a paragraph break gives two.
    public let lines: [Paragraph]
    public let comments: [Comment]

    /// `lines` copied from `scene`, with the comments they mention.
    public init(_ lines: [Paragraph], from scene: BookScene) {
        let mentioned = Paragraph.commentIDs(in: lines)
        self.init(
            scene: scene.id, lines: lines, comments: scene.comments.filter { mentioned.contains($0.id) })
    }

    private init(scene: SceneID, lines: [Paragraph], comments: [Comment]) {
        self.scene = scene
        self.lines = lines
        self.comments = comments
    }

    /// The clip as pasteboard data; `nil` if it wouldn't read back as itself.
    public var data: Data? {
        let holder = BookScene(
            id: scene, modified: BookFormat.rereadTime, title: "", body: lines, comments: comments)
        return try? BookFormat.verifiedSerialization(of: Book(title: "", scenes: [holder]))
    }

    /// The clip `data` holds; `nil` if it holds no scene.
    public init?(data: Data) {
        var ids = UnusedSceneIDs()
        guard let scene = BookFormat.parse(data, opened: BookFormat.rereadTime, ids: &ids).book.scenes.first
        else { return nil }
        self.init(scene: scene.id, lines: scene.body, comments: scene.comments)
    }

    /// The clip's lines as pasting them into `destination` writes them, and the comments the
    /// paste adds to it. A comment keeps its id only when the clip came from `destination`
    /// and the comment is still there; every other comment is copied with a fresh id, and an
    /// id the clip has no comment for is dropped.
    public func resolved(into destination: BookScene, ids: inout IDGenerator<some RandomNumberGenerator>)
        -> (lines: [Paragraph], comments: [Comment])
    {
        let present = Set(destination.comments.map(\.id))
        var newIDs: [CommentID: CommentID] = [:]
        var copies: [Comment] = []
        for comment in comments {
            if scene == destination.id, present.contains(comment.id) {
                newIDs[comment.id] = comment.id
            } else {
                var copy = comment
                copy.id = ids.commentID()
                newIDs[comment.id] = copy.id
                copies.append(copy)
            }
        }
        let lines = lines.map { paragraph in
            Paragraph(
                paragraph.runs.map { run in
                    var run = run
                    run.comments = Set(run.comments.compactMap { newIDs[$0] })
                    return run
                })
        }
        return (lines, copies)
    }
}
