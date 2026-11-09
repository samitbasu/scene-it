import Foundation

/// Export to Word (PLAN §10.2, ADR 0045, 0047): a scene as a .docx that Scene It writes itself,
/// a minimal WordprocessingML package. The title paragraph has Word's Heading 1 style and the body
/// the default style (`WordStyles`); each run carries only its own bold, italic, strikethrough,
/// colour and highlight, its typography smartened as print's is (decision 0022). Comments and
/// notes aren't exported.
public enum WordExport {
    public static func document(of scene: BookScene) throws(WordExportFailure) -> Data {
        let document = try WordDocument.document(OutputParagraph.paragraphs(of: scene))
        do {
            return try ZipWriter.archive([
                .init(name: "[Content_Types].xml", bytes: Data(WordDocument.contentTypes.utf8)),
                .init(name: "_rels/.rels", bytes: Data(WordDocument.packageRelationships.utf8)),
                .init(name: "word/document.xml", bytes: Data(document.utf8)),
                .init(
                    name: "word/_rels/document.xml.rels", bytes: Data(WordDocument.documentRelationships.utf8)
                ),
                .init(name: "word/styles.xml", bytes: Data(WordStyles.xml.utf8)),
                .init(name: "word/settings.xml", bytes: Data(WordDocument.settings.utf8)),
            ])
        } catch {
            throw .tooLarge
        }
    }
}

/// The package's XML parts other than the styles. Elements are written in the order the schema
/// (ECMA-376) requires.
enum WordDocument {
    enum Namespace {
        static let word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        static let contentTypes = "http://schemas.openxmlformats.org/package/2006/content-types"
        static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
        static let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    }

    private static let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    static let contentTypes =
        declaration + #"<Types xmlns="\#(Namespace.contentTypes)">"#
        + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
        + #"<Default Extension="xml" ContentType="application/xml"/>"#
        + #"<Override PartName="/word/document.xml" "#
        + #"ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>"#
        + #"<Override PartName="/word/styles.xml" "#
        + #"ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>"#
        + #"<Override PartName="/word/settings.xml" "#
        + #"ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>"#
        + "</Types>"

    static let packageRelationships =
        declaration + #"<Relationships xmlns="\#(Namespace.packageRelationships)">"#
        + #"<Relationship Id="rId1" Type="\#(Namespace.officeRelationships)/officeDocument" "#
        + #"Target="word/document.xml"/></Relationships>"#

    static let documentRelationships =
        declaration + #"<Relationships xmlns="\#(Namespace.packageRelationships)">"#
        + #"<Relationship Id="rId1" Type="\#(Namespace.officeRelationships)/styles" Target="styles.xml"/>"#
        + #"<Relationship Id="rId2" Type="\#(Namespace.officeRelationships)/settings" Target="settings.xml"/>"#
        + "</Relationships>"

    /// Word's current compatibility mode (15, Word 2013 and later); without it, Word opens the
    /// document in Compatibility Mode, as if an older Word had written it.
    static let settings =
        declaration + #"<w:settings xmlns:w="\#(Namespace.word)"><w:compat>"#
        + #"<w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" "#
        + #"w:val="15"/></w:compat></w:settings>"#

    static func document(_ paragraphs: [OutputParagraph]) throws(WordExportFailure) -> String {
        var body = ""
        for paragraph in paragraphs {
            body += try self.paragraph(paragraph)
        }
        return declaration + #"<w:document xmlns:w="\#(Namespace.word)"><w:body>"# + body
            + "</w:body></w:document>"
    }

    private static func paragraph(_ paragraph: OutputParagraph) throws(WordExportFailure) -> String {
        let properties =
            switch paragraph.kind {
            case .title: #"<w:pPr><w:pStyle w:val="\#(WordStyles.headingID)"/></w:pPr>"#
            case .body: ""
            }
        var runs = ""
        for piece in merged(paragraph.shown) {
            runs += try run(piece.run, showing: piece.text)
        }
        return "<w:p>" + properties + runs + "</w:p>"
    }

    /// Neighbouring runs Word would format alike joined into one, so a comment's edge, which
    /// isn't exported, doesn't split a run.
    static func merged(_ pieces: [(run: Run, text: String)]) -> [(run: Run, text: String)] {
        var merged: [(run: Run, text: String)] = []
        for piece in pieces {
            if let last = merged.last, last.run.styles == piece.run.styles, last.run.color == piece.run.color,
                last.run.highlight == piece.run.highlight
            {
                merged[merged.count - 1].text += piece.text
            } else {
                merged.append(piece)
            }
        }
        return merged
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
        let formatting = properties.isEmpty ? "" : "<w:rPr>" + properties + "</w:rPr>"
        return "<w:r>" + formatting + #"<w:t xml:space="preserve">"# + (try escaped(text))
            + "</w:t></w:r>"
    }

    private static func hex(_ rgb: UInt32) -> String {
        String(format: "%06X", rgb)
    }

    /// `text` as XML character data. It refuses a character XML 1.0 can't hold at all (a control
    /// character other than tab, line feed and carriage return, or U+FFFE and U+FFFF; a `String`
    /// can't hold a lone surrogate), so a document Word would reject is never written.
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
    /// The scene holds a character XML can't, so no Word document can.
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
