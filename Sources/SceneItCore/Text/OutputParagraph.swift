/// A paragraph of a scene as print and Export to Word put it out (decision 0015): the title as a
/// heading, then the body.
struct OutputParagraph: Hashable {
    enum Kind: Hashable {
        case title, body

        var role: ParagraphRole {
            switch self {
            case .title: .title
            case .body: .body
            }
        }
    }

    let kind: Kind
    let runs: [Run]

    /// The scene's title, unless it has none, then its body. A scene with nothing at all is one
    /// empty paragraph, as an empty document is.
    static func paragraphs(of scene: BookScene) -> [OutputParagraph] {
        let title =
            scene.title.text.isEmpty ? [] : [OutputParagraph(kind: .title, runs: [Run(scene.title.text)])]
        let paragraphs = title + scene.body.map { OutputParagraph(kind: .body, runs: $0.runs) }
        return paragraphs.isEmpty ? [OutputParagraph(kind: .body, runs: [])] : paragraphs
    }
}
