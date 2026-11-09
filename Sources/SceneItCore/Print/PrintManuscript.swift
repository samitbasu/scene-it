import AppKit

/// The print dialog's two layouts (PLAN §10.1).
public enum PrintLayout: Hashable, Sendable, CaseIterable {
    /// Portrait, in manuscript format.
    case textOnly
    /// Landscape, the comments in a column beside the lines they refer to.
    case withComments

    public var orientation: PaperOrientation {
        switch self {
        case .textOnly: .portrait
        case .withComments: .landscape
        }
    }
}

public enum PaperOrientation: Hashable, Sendable {
    case portrait, landscape
}

/// What the print dialog prints (PLAN §10.1). The Boneyard is never part of the manuscript.
public enum PrintRange: Hashable, Sendable, CaseIterable {
    case thisScene, wholeManuscript

    /// The ranges there's something to print in: this scene while one is open, the whole
    /// manuscript while the story has a scene. None means nothing to print.
    public static func offered(in book: Book, open: SceneID?) -> [PrintRange] {
        allCases.filter { !$0.scenes(of: book, open: open).isEmpty }
    }

    /// The scenes printed from `book` with `open` the scene showing: none for this scene when
    /// none is open.
    public func scenes(of book: Book, open: SceneID?) -> [BookScene] {
        switch self {
        case .thisScene: book.scene(open).map { [$0] } ?? []
        case .wholeManuscript: book.scenes
        }
    }
}

/// Scenes as print puts them out (PLAN §10.1): each scene's title as its heading, then its body,
/// the typography smartened (decision 0022); and the comments on them, each with the stretch of
/// text its underline starts with.
public struct PrintManuscript {
    let text: NSAttributedString
    /// Where each scene after the first starts in `text`.
    let sceneStarts: Set<Int>
    /// In the order they start in `text`, the older first of two starting together.
    let comments: [PrintComment]
    let palette: CommentPalette

    public init(_ scenes: [BookScene]) {
        let paragraphs = scenes.map(OutputParagraph.paragraphs(of:))
        text = RunCodec.attributedString(forOutput: paragraphs.flatMap(\.self))
        let string = text.string as NSString
        var starts: Set<Int> = []
        var location = 0
        for scene in paragraphs.dropLast() {
            for _ in scene {
                location = NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0)))
            }
            starts.insert(location)
        }
        sceneStarts = starts
        let all = scenes.flatMap(\.comments)
        palette = CommentPalette(all)
        comments = PrintComment.comments(all, in: text)
    }

    /// Whether any of the scenes' comments is on their text.
    public var hasComments: Bool {
        !comments.isEmpty
    }
}

/// A comment as printed beside the text.
struct PrintComment {
    let color: PaletteColor
    /// Smartened, as the text is.
    let text: String
    /// The first stretch of the printed text it covers, where its connector points.
    let firstStretch: NSRange

    /// `comments` that cover some of `text`, in order.
    static func comments(_ comments: [Comment], in text: NSAttributedString) -> [PrintComment] {
        var stretches: [CommentID: NSRange] = [:]
        text.enumerateAttribute(.comments, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            for id in CommentPalette.ids(in: value) {
                if let stretch = stretches[id] {
                    if stretch.upperBound == range.location { stretches[id] = stretch.union(range) }
                } else {
                    stretches[id] = range
                }
            }
        }
        let placed = comments.enumerated().compactMap { order, comment in
            stretches[comment.id].map { (comment, order, $0) }
        }
        return
            placed
            .sorted {
                ($0.2.location, $0.0.created.secondsSince1970, $0.1) < (
                    $1.2.location, $1.0.created.secondsSince1970, $1.1
                )
            }
            .map {
                PrintComment(color: $0.0.color, text: Typography.smartened($0.0.text), firstStretch: $0.2)
            }
    }
}
