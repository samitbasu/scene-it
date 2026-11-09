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

    /// How the paragraph is cut into pieces before they're smartened.
    enum Pieces {
        /// Each run is a piece: print, which underlines each run's comments.
        case eachRun
        /// Neighbouring runs that look alike (styles, colour, highlight) are one piece: Word
        /// without its comments, so a `--` split only by a comment's edge is still a dash.
        case sameLook
        /// Neighbouring runs alike in look and comments are one piece: Word with its comments,
        /// whose ranges start and end at the pieces' edges, so a `--` split by a comment's edge
        /// stays two hyphens.
        case sameFormat

        func joins(_ run: Run, to last: Run) -> Bool {
            switch self {
            case .eachRun: false
            case .sameLook: run.hasSameLook(as: last)
            case .sameFormat: run.hasSameFormat(as: last)
            }
        }
    }

    /// The paragraph's pieces as print and Export to Word show them, each with a run that
    /// carries its formatting: the typography smartened over the whole paragraph (decision 0022),
    /// so a piece keeps exactly its characters. A `--` or `...` split between pieces stays as it
    /// is. The stored text is never smartened.
    func shown(_ pieces: Pieces) -> [(run: Run, text: String)] {
        var groups: [(run: Run, length: Int)] = []
        for run in runs {
            let length = run.text.unicodeScalars.count
            if let last = groups.last, pieces.joins(run, to: last.run) {
                groups[groups.count - 1].length += length
            } else {
                groups.append((run, length))
            }
        }
        let unit = SmartUnit(runs.map(\.text).joined())
        var offset = 0
        return groups.map { group in
            defer { offset += group.length }
            return (group.run, unit.piece(offset..<offset + group.length))
        }
    }

    /// The scene's title, unless it has none, then its body. A scene with nothing at all is one
    /// empty paragraph, as an empty document is.
    static func paragraphs(of scene: BookScene) -> [OutputParagraph] {
        let title =
            scene.title.text.isEmpty ? [] : [OutputParagraph(kind: .title, runs: [Run(scene.title.text)])]
        let paragraphs = title + scene.body.map { OutputParagraph(kind: .body, runs: $0.runs) }
        return paragraphs.isEmpty ? [OutputParagraph(kind: .body, runs: [])] : paragraphs
    }
}
