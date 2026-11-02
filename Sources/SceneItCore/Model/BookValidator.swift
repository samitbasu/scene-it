/// The rules a decoded book must satisfy that its types can't express.
public enum BookValidator {
    /// Every problem in `book`, in document order; empty when the book is valid.
    public static func problems(in book: Book) -> [BookProblem] {
        var problems: [BookProblem] = []
        var seen: Set<SceneID> = []
        for (list, scenes) in [(SceneList.scenes, book.scenes), (.boneyard, book.boneyard)] {
            for (index, scene) in scenes.enumerated() {
                let place = ScenePlace(list: list, index: index, id: scene.id)
                if !seen.insert(scene.id).inserted {
                    problems.append(.duplicateSceneID(place))
                }
                problems += self.problems(in: scene, at: place)
            }
        }
        return problems
    }

    private static func problems(in scene: BookScene, at place: ScenePlace) -> [BookProblem] {
        var problems: [BookProblem] = []
        var commentIDs: Set<CommentID> = []
        for comment in scene.comments where !commentIDs.insert(comment.id).inserted {
            problems.append(.duplicateCommentID(place, comment.id))
        }
        if scene.title.text.contains(where: \.isLineBreak) {
            problems.append(.lineBreakInTitle(place))
        }
        let fields: [(SceneTextPart, [Paragraph])] = [(.body, scene.body), (.notes, scene.notes)]
        for (field, paragraphs) in fields {
            for (paragraphIndex, paragraph) in paragraphs.enumerated() {
                for (runIndex, run) in paragraph.runs.enumerated() {
                    let location = TextLocation(
                        scene: place, field: field, paragraph: paragraphIndex, run: runIndex)
                    if run.text.isEmpty {
                        problems.append(.emptyRun(location))
                    }
                    if run.text.contains(where: \.isLineBreak) {
                        problems.append(.lineBreak(location))
                    }
                    for id in run.comments.sorted() where !commentIDs.contains(id) {
                        problems.append(.missingComment(location, id))
                    }
                }
            }
        }
        return problems
    }
}

public enum SceneList: String, Hashable, Sendable {
    case scenes, boneyard
}

public struct ScenePlace: Hashable, Sendable, CustomStringConvertible {
    public let list: SceneList
    public let index: Int
    public let id: SceneID

    public var description: String {
        "scene \"\(id)\" (\(list.rawValue)[\(index)])"
    }
}

public enum SceneTextPart: String, Hashable, Sendable {
    case body, notes
}

public struct TextLocation: Hashable, Sendable, CustomStringConvertible {
    public let scene: ScenePlace
    public let field: SceneTextPart
    public let paragraph: Int
    public let run: Int

    public var description: String {
        "\(scene), \(field.rawValue)[\(paragraph)][\(run)]"
    }
}

public enum BookProblem: Error, Hashable, Sendable, CustomStringConvertible {
    case duplicateSceneID(ScenePlace)
    case duplicateCommentID(ScenePlace, CommentID)
    case missingComment(TextLocation, CommentID)
    case emptyRun(TextLocation)
    case lineBreak(TextLocation)
    case lineBreakInTitle(ScenePlace)

    public var description: String {
        switch self {
        case .duplicateSceneID(let place):
            "\(place): another scene already has the id \"\(place.id)\""
        case .duplicateCommentID(let place, let id):
            "\(place), comments: the id \"\(id)\" is used by more than one comment"
        case .missingComment(let location, let id):
            "\(location): comment \"\(id)\" is not in the scene's comments"
        case .emptyRun(let location):
            "\(location): a run's text is empty"
        case .lineBreak(let location):
            "\(location): a paragraph's text contains a line break"
        case .lineBreakInTitle(let place):
            "\(place), title: the title must be one line, but it contains a line break"
        }
    }
}
