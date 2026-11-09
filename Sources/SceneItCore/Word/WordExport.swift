import Foundation

/// Export to Word (PLAN §10.2, ADR 0045, 0047, 0048): a scene as a .docx that Scene It writes
/// itself, a minimal WordprocessingML package. The title paragraph has Word's Heading 1 style and
/// the body the default style (`WordStyles`); each run carries only its own bold, italic,
/// strikethrough, colour and highlight, its typography smartened as print's is (decision 0022).
/// The scene's comments become Word's comments when the writer asks for them; notes never go.
public enum WordExport {
    public static func document(of scene: BookScene, comments: WordComments) throws(WordExportFailure) -> Data
    {
        let paragraphs = OutputParagraph.paragraphs(of: scene)
        let list = WordCommentList(scene, comments)
        let parts = [WordDocument.Part.styles, .settings] + (list == nil ? [] : [.comments])
        var entries: [ZipWriter.Entry] = [
            .init(name: "[Content_Types].xml", bytes: Data(WordDocument.contentTypes(parts).utf8)),
            .init(name: "_rels/.rels", bytes: Data(WordDocument.packageRelationships.utf8)),
            .init(
                name: WordDocument.Part.document.name,
                bytes: Data(try WordDocument.document(paragraphs, list).utf8)),
            .init(
                name: "word/_rels/document.xml.rels",
                bytes: Data(WordDocument.documentRelationships(parts).utf8)),
            .init(name: WordDocument.Part.styles.name, bytes: Data(WordStyles.xml(for: parts).utf8)),
            .init(name: WordDocument.Part.settings.name, bytes: Data(WordDocument.settings.utf8)),
        ]
        if let list {
            entries.append(.init(name: WordDocument.Part.comments.name, bytes: Data(try list.xml().utf8)))
        }
        do {
            return try ZipWriter.archive(entries)
        } catch {
            throw .tooLarge
        }
    }
}

/// Whether Export to Word writes the scene's comments, and as whose.
public enum WordComments: Hashable, Sendable {
    case omitted
    case included(by: CommentAuthor)
}

/// The save panel's Include comments checkbox.
public enum WordCommentChoice: Hashable, Sendable {
    case omit, include

    /// The choice a checkbox ticked (`true`) or not shows.
    public init(ticked: Bool) {
        self = ticked ? .include : .omit
    }

    /// Whether the checkbox showing this choice is ticked.
    public var isTicked: Bool {
        self == .include
    }

    /// What the export writes for this choice, by `author`.
    public func comments(by author: CommentAuthor) -> WordComments {
        switch self {
        case .omit: .omitted
        case .include: .included(by: author)
        }
    }
}

/// Who Word says wrote the exported comments: a name, and initials from it.
public struct CommentAuthor: Hashable, Sendable {
    public let name: String
    public let initials: String

    /// `fullName`'s words, or `WordExportWording.unnamedAuthor` when it has none; the initials
    /// are each word's first letter.
    public init(fullName: String) {
        let words = fullName.split(whereSeparator: \.isWhitespace)
        let named = words.isEmpty ? WordExportWording.unnamedAuthor.split(separator: " ") : words
        name = named.joined(separator: " ")
        initials = String(named.compactMap(\.first)).uppercased()
    }
}

/// The comments an exported document carries: the scene's anchored comments, in the order their
/// text starts (as the Comments tab lists them, `CommentCards`), each numbered as its Word id by
/// its place in that order. Detached comments have no text to anchor to, so they're left out.
struct WordCommentList {
    let author: CommentAuthor
    let comments: [Comment]
    let numbers: [CommentID: Int]

    init?(_ scene: BookScene, _ choice: WordComments) {
        guard case .included(let author) = choice else { return nil }
        self.author = author
        comments = CommentCards(scene).anchored.map(\.comment)
        numbers = Dictionary(uniqueKeysWithValues: comments.enumerated().map { ($1.id, $0) })
    }

    /// `word/comments.xml`: each comment's text, smartened as print's comments are, one paragraph
    /// a line, dated with its creation's local time and no offset (ADR 0048: how Word reads that
    /// is unverified until a hand test).
    func xml() throws(WordExportFailure) -> String {
        let name = try WordDocument.escaped(author.name)
        let initials = try WordDocument.escaped(author.initials)
        var body = ""
        for (number, comment) in comments.enumerated() {
            var paragraphs = ""
            let lines = Typography.smartened(comment.text).split(
                separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let reference = index == 0 ? WordDocument.referenceRun("<w:annotationRef/>") : ""
                let text =
                    line.isEmpty ? "" : WordDocument.textRun("", try WordDocument.escaped(String(line)))
                paragraphs +=
                    #"<w:p><w:pPr><w:pStyle w:val="\#(WordStyles.commentID)"/></w:pPr>"#
                    + reference + text + "</w:p>"
            }
            body +=
                #"<w:comment w:id="\#(number)" w:author="\#(name)" "#
                + #"w:date="\#(comment.created.localDescription)" w:initials="\#(initials)">"#
                + paragraphs + "</w:comment>"
        }
        return WordDocument.declaration + #"<w:comments xmlns:w="\#(WordDocument.Namespace.word)">"# + body
            + "</w:comments>"
    }

    /// Where each comment's range starts and ends among the document's pieces: it starts before
    /// the first piece it covers and ends after the last, in whichever paragraphs those are.
    /// Ranges starting together open longest first and ranges ending together close in the
    /// reverse of the order they opened, so they nest; others overlap as their text does.
    func boundaries(_ pieces: [[(run: Run, text: String)]]) -> CommentBoundaries {
        var first: [Int: PiecePlace] = [:]
        var last: [Int: PiecePlace] = [:]
        for (paragraph, paragraphPieces) in pieces.enumerated() {
            for (piece, shown) in paragraphPieces.enumerated() {
                for id in shown.run.comments {
                    guard let number = numbers[id] else { continue }
                    let place = PiecePlace(paragraph: paragraph, piece: piece)
                    if first[number] == nil { first[number] = place }
                    last[number] = place
                }
            }
        }
        let opening = first.compactMap { number, start in
            last[number].map { (number: number, start: start, end: $0) }
        }
        .sorted { ($0.start, $1.end, $0.number) < ($1.start, $0.end, $1.number) }
        var starts: [PiecePlace: [Int]] = [:]
        var ends: [PiecePlace: [Int]] = [:]
        for range in opening {
            starts[range.start, default: []].append(range.number)
        }
        for range in opening.reversed() {
            ends[range.end, default: []].append(range.number)
        }
        return CommentBoundaries(starts: starts, ends: ends)
    }
}

struct PiecePlace: Hashable, Comparable {
    let paragraph: Int
    let piece: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.paragraph, lhs.piece) < (rhs.paragraph, rhs.piece)
    }
}

/// The Word ids of the comment ranges that start before, and end after, each piece.
struct CommentBoundaries {
    static let none = CommentBoundaries(starts: [:], ends: [:])

    let starts: [PiecePlace: [Int]]
    let ends: [PiecePlace: [Int]]
}

/// The package's XML parts other than the styles and comments. Elements are written in the order
/// the schema (ECMA-376) requires.
enum WordDocument {
    enum Namespace {
        static let word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        static let contentTypes = "http://schemas.openxmlformats.org/package/2006/content-types"
        static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
        static let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    }

    /// The parts of `word/`, with their content types and how the main document links to them.
    enum Part {
        case document, styles, settings, comments

        var name: String {
            "word/" + file
        }

        var file: String {
            switch self {
            case .document: "document.xml"
            case .styles: "styles.xml"
            case .settings: "settings.xml"
            case .comments: "comments.xml"
            }
        }

        var contentType: String {
            let kind =
                switch self {
                case .document: "document.main"
                case .styles: "styles"
                case .settings: "settings"
                case .comments: "comments"
                }
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.\(kind)+xml"
        }

        /// The relationship's type, after the office relationships namespace.
        var relationship: String {
            switch self {
            case .document: "officeDocument"
            case .styles: "styles"
            case .settings: "settings"
            case .comments: "comments"
            }
        }
    }

    static let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    /// The types of the main document and the parts it links to.
    static func contentTypes(_ linked: [Part]) -> String {
        let overrides = ([Part.document] + linked).map {
            #"<Override PartName="/\#($0.name)" ContentType="\#($0.contentType)"/>"#
        }
        return declaration + #"<Types xmlns="\#(Namespace.contentTypes)">"#
            + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
            + #"<Default Extension="xml" ContentType="application/xml"/>"# + overrides.joined() + "</Types>"
    }

    static let packageRelationships =
        declaration + #"<Relationships xmlns="\#(Namespace.packageRelationships)">"#
        + #"<Relationship Id="rId1" Type="\#(Namespace.officeRelationships)/\#(Part.document.relationship)" "#
        + #"Target="\#(Part.document.name)"/></Relationships>"#

    static func documentRelationships(_ linked: [Part]) -> String {
        let links = linked.enumerated().map { index, part in
            #"<Relationship Id="rId\#(index + 1)" Type="\#(Namespace.officeRelationships)/\#(part.relationship)" "#
                + #"Target="\#(part.file)"/>"#
        }
        return declaration + #"<Relationships xmlns="\#(Namespace.packageRelationships)">"# + links.joined()
            + "</Relationships>"
    }

    /// Word's current compatibility mode (15, Word 2013 and later); without it, Word opens the
    /// document in Compatibility Mode, as if an older Word had written it.
    static let settings =
        declaration + #"<w:settings xmlns:w="\#(Namespace.word)"><w:compat>"#
        + #"<w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" "#
        + #"w:val="15"/></w:compat></w:settings>"#

    /// The body. Without comments, runs Word would format alike are joined; with them, runs are
    /// joined only where the comments are the same too, since a comment's range starts and ends
    /// between runs.
    static func document(_ paragraphs: [OutputParagraph], _ comments: WordCommentList?)
        throws(WordExportFailure)
        -> String
    {
        let pieces = paragraphs.map { $0.shown(comments == nil ? .sameLook : .sameFormat) }
        let boundaries = comments?.boundaries(pieces) ?? .none
        var body = ""
        for (index, paragraph) in paragraphs.enumerated() {
            body += try self.paragraph(paragraph.kind, pieces[index], number: index, boundaries)
        }
        return declaration + #"<w:document xmlns:w="\#(Namespace.word)"><w:body>"# + body
            + "</w:body></w:document>"
    }

    private static func paragraph(
        _ kind: OutputParagraph.Kind, _ pieces: [(run: Run, text: String)], number: Int,
        _ boundaries: CommentBoundaries
    ) throws(WordExportFailure) -> String {
        let properties =
            switch kind {
            case .title: #"<w:pPr><w:pStyle w:val="\#(WordStyles.headingID)"/></w:pPr>"#
            case .body: ""
            }
        var content = ""
        for (index, piece) in pieces.enumerated() {
            let place = PiecePlace(paragraph: number, piece: index)
            for id in boundaries.starts[place] ?? [] {
                content += #"<w:commentRangeStart w:id="\#(id)"/>"#
            }
            content += try run(piece.run, showing: piece.text)
            for id in boundaries.ends[place] ?? [] {
                content +=
                    #"<w:commentRangeEnd w:id="\#(id)"/>"#
                    + referenceRun(#"<w:commentReference w:id="\#(id)"/>"#)
            }
        }
        return "<w:p>" + properties + content + "</w:p>"
    }

    /// A run's own formatting, in the schema's order: bold, italic, strikethrough, colour, shading.
    /// Uncoloured text has no colour of its own, so it's Word's automatic colour: black on a white
    /// page, light when Word shows the document dark.
    private static func run(_ run: Run, showing text: String) throws(WordExportFailure) -> String {
        var properties = ""
        if run.styles.contains(.bold) { properties += "<w:b/>" }
        if run.styles.contains(.italic) { properties += "<w:i/>" }
        if run.styles.contains(.strike) { properties += "<w:strike/>" }
        if let color = run.color {
            properties += #"<w:color w:val="\#(hex(PaletteColor(color).hex))"/>"#
        }
        if let highlight = run.highlight {
            properties += #"<w:shd w:val="clear" w:color="auto" w:fill="\#(hex(highlight.hex))"/>"#
        }
        return textRun(properties, try escaped(text))
    }

    /// A run holding a comment's mark `mark`, in Word's style for it.
    static func referenceRun(_ mark: String) -> String {
        #"<w:r><w:rPr><w:rStyle w:val="\#(WordStyles.commentReferenceID)"/></w:rPr>"# + mark + "</w:r>"
    }

    /// A run of `escapedText` with the run properties `properties`, if any.
    static func textRun(_ properties: String, _ escapedText: String) -> String {
        let formatting = properties.isEmpty ? "" : "<w:rPr>" + properties + "</w:rPr>"
        return "<w:r>" + formatting + #"<w:t xml:space="preserve">"# + escapedText + "</w:t></w:r>"
    }

    private static func hex(_ rgb: UInt32) -> String {
        String(format: "%06X", rgb)
    }

    /// `text` as XML character data or an attribute's value. It refuses a character XML 1.0 can't
    /// hold at all (a control character other than tab, line feed and carriage return, or U+FFFE
    /// and U+FFFF; a `String` can't hold a lone surrogate), so a document Word would reject is
    /// never written.
    static func escaped(_ text: String) throws(WordExportFailure) -> String {
        guard text.unicodeScalars.allSatisfy(isXMLCharacter) else { throw .unwritableCharacter }
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    /// XML 1.0's `Char` production.
    static func isXMLCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x1_0000...0x10_FFFF: true
        default: false
        }
    }
}

/// Why Export to Word wrote nothing. Nothing at the destination changed.
public enum WordExportFailure: Error, Hashable, Sendable {
    /// The destination isn't named as a Word document (`.docx`).
    case notAWordDocument
    /// The scene is beyond what a .docx without zip64 can hold, 4 GiB.
    case tooLarge
    /// The scene, its comments or their author's name holds a character XML can't, so no Word
    /// document can.
    case unwritableCharacter
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
