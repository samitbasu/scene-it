import AppKit

/// Export to Word (PLAN §10.2, ADR 0045): a scene as a .docx. macOS writes the document from an
/// attributed string, then `WordPackage` marks the title as Word's Heading 1 and adds what macOS's
/// writer leaves out: named styles, double spacing, highlights and the palette's exact colours.
public enum WordExport {
    public static func document(of scene: BookScene) throws(WordExportFailure) -> Data {
        let paragraphs = WordParagraph.paragraphs(of: scene)
        let text = attributedString(paragraphs)
        let written: Data
        do {
            written = try text.data(
                from: NSRange(location: 0, length: text.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        } catch {
            Log.store.error(
                "macOS couldn't write the scene as a .docx", ["error": .error(LoggedError(error))])
            throw .conversion
        }
        return try WordPackage.restyled(written, paragraphs)
    }

    /// The paragraphs one after another, each run in its role's fonts and colours. Comments are
    /// left out.
    static func attributedString(_ paragraphs: [WordParagraph]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            for run in paragraph.runs {
                text.append(
                    NSAttributedString(string: run.text, attributes: paragraph.kind.attributes(of: run)))
            }
            if index < paragraphs.count - 1 {
                text.append(
                    NSAttributedString(string: "\n", attributes: paragraph.kind.attributes(of: Run(""))))
            }
        }
        return text
    }
}

/// A paragraph of the exported document.
struct WordParagraph: Hashable {
    enum Kind: Hashable {
        case title, body

        var role: ParagraphRole {
            switch self {
            case .title: .title
            case .body: .body
            }
        }

        func attributes(of run: Run) -> [NSAttributedString.Key: Any] {
            var format = RunFormat(run)
            format.comments = []
            var attributes = format.attributes(in: role)
            attributes[.paragraphStyle] = paragraphStyle
            return attributes
        }

        /// What macOS's writer keeps of the page's paragraph style: it drops line spacing, which
        /// the document's styles give instead (`WordStyles`).
        private var paragraphStyle: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            if self == .body {
                style.firstLineHeadIndent = ParagraphRole.firstLineIndent
            }
            return style
        }
    }

    let kind: Kind
    let runs: [Run]

    var text: String {
        runs.map(\.text).joined()
    }

    /// The scene's title, unless it has none, then its body. A blank line ending the body would
    /// only be white space at the end of the document, and macOS's writer drops the last one, so
    /// none is exported; a scene with nothing at all is one empty paragraph, as an empty Word
    /// document is.
    static func paragraphs(of scene: BookScene) -> [WordParagraph] {
        var body = scene.body
        while body.last?.runs.isEmpty == true {
            body.removeLast()
        }
        let title =
            scene.title.text.isEmpty ? [] : [WordParagraph(kind: .title, runs: [Run(scene.title.text)])]
        let paragraphs = title + body.map { WordParagraph(kind: .body, runs: $0.runs) }
        return paragraphs.isEmpty ? [WordParagraph(kind: .body, runs: [])] : paragraphs
    }
}

/// Why Export to Word wrote nothing. Nothing at the destination changed.
public enum WordExportFailure: Error, Hashable, Sendable {
    /// The destination isn't named as a Word document (`.docx`).
    case notAWordDocument
    /// macOS couldn't write the scene as a .docx, or wrote one Scene It doesn't recognise, so it
    /// couldn't be restyled.
    case conversion
    case destination(ChosenFileFailure)
}

/// What `BookStore.exportToWord` did.
public enum WordExportResult: Hashable, Sendable {
    case exported
    case failed(WordExportFailure)
    /// The book closed, or the scene is gone, by the time the export's turn came; nothing was
    /// written.
    case unavailable
}
