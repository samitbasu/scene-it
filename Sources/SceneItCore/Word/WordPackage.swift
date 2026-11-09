import Foundation

/// Restyles the .docx macOS writes (ADR 0045). The title paragraph gets Word's `Heading1` style,
/// so Word lists it in its Navigation pane and a table of contents; `word/styles.xml` defines that
/// style and the body's (`WordStyles`), which carry the double spacing macOS's writer drops; and
/// each run gets the palette's exact colours, with highlights shaded, which macOS's writer drops.
///
/// Each paragraph's text is checked against the scene's before anything is changed, and a
/// document laid out other than expected is refused rather than guessed at.
enum WordPackage {
    static let documentPart = "word/document.xml"
    static let stylesPart = "word/styles.xml"
    static let contentTypesPart = "[Content_Types].xml"
    static let documentRelationshipsPart = "word/_rels/document.xml.rels"

    static func restyled(_ docx: Data, _ paragraphs: [WordParagraph]) throws(WordExportFailure) -> Data {
        do throws(Unexpected) {
            var archive: ZipArchive
            do {
                archive = try ZipArchive(reading: docx)
            } catch {
                throw Unexpected("not a zip macOS's writer makes")
            }
            guard archive[stylesPart] == nil else { throw Unexpected("styles already there") }
            guard let document = archive[documentPart], let types = archive[contentTypesPart],
                let relationships = archive[documentRelationshipsPart]
            else { throw Unexpected("a part is missing") }
            archive[documentPart] = try styledDocument(document, paragraphs)
            archive[contentTypesPart] = try addingStylesType(to: types)
            archive[documentRelationshipsPart] = try addingStylesRelationship(to: relationships)
            archive[stylesPart] = Data(WordStyles.xml.utf8)
            do {
                return try archive.data()
            } catch {
                throw Unexpected("too large to zip")
            }
        } catch {
            Log.store.error("Couldn't restyle the .docx", ["reason": .symbol(error.reason)])
            throw .conversion
        }
    }

    private struct Unexpected: Error {
        let reason: StaticString

        init(_ reason: StaticString) {
            self.reason = reason
        }
    }

    private enum Namespace {
        static let word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        static let contentTypes = "http://schemas.openxmlformats.org/package/2006/content-types"
        static let relationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    }

    // MARK: The document

    private static func styledDocument(_ data: Data, _ paragraphs: [WordParagraph]) throws(Unexpected) -> Data
    {
        let xml = try parse(data)
        guard let root = xml.rootElement(), let prefix = root.resolvePrefix(forNamespaceURI: Namespace.word),
            let body = root.elements(forLocalName: "body", uri: Namespace.word).first
        else { throw Unexpected("no document body") }
        let word = WordElements(prefix: prefix)
        let written = body.elements(forLocalName: "p", uri: Namespace.word)
        guard written.count == paragraphs.count else { throw Unexpected("paragraphs don't match") }
        for (element, paragraph) in zip(written, paragraphs) {
            try colorRuns(in: element, paragraph, word)
            if paragraph.kind == .title {
                word.properties(of: element, named: "pPr").insertChild(
                    word.element("pStyle", ["val": WordStyles.headingID]), at: 0)
            }
        }
        return serialized(xml)
    }

    /// A run's colours as the palette defines them.
    private struct RunColors: Hashable {
        let text: PaletteColor
        let highlight: HighlightColor?

        init(_ run: Run) {
            text = PaletteColor(run.color)
            highlight = run.highlight
        }
    }

    /// Gives each run macOS wrote its text colour exactly as the palette has it (macOS's writer
    /// converts it to another colour space, a shade darker), and shades the highlighted ones. macOS
    /// writes a run wherever any attribute changes, so a run is never partly coloured.
    private static func colorRuns(in element: XMLElement, _ paragraph: WordParagraph, _ word: WordElements)
        throws(Unexpected)
    {
        let colors = paragraph.runs.flatMap { Array(repeating: RunColors($0), count: $0.text.count) }
        var written = ""
        for run in element.elements(forLocalName: "r", uri: Namespace.word) {
            let text = run.elements(forLocalName: "t", uri: Namespace.word).compactMap(\.stringValue).joined()
            let range = written.count..<written.count + text.count
            written += text
            guard range.upperBound <= colors.count else { throw Unexpected("text doesn't match") }
            let runColors = Set(colors[range])
            guard runColors.count <= 1 else { throw Unexpected("a run is partly coloured") }
            guard let color = runColors.first else { continue }
            let properties = word.properties(of: run, named: "rPr")
            for converted in properties.elements(forLocalName: "color", uri: Namespace.word) {
                converted.detach()
            }
            properties.addChild(word.element("color", ["val": Self.hex(color.text.hex)]))
            if let highlight = color.highlight {
                properties.addChild(
                    word.element("shd", ["val": "clear", "color": "auto", "fill": Self.hex(highlight.hex)]))
            }
        }
        guard written == paragraph.text else { throw Unexpected("text doesn't match") }
    }

    private static func hex(_ rgb: UInt32) -> String {
        String(format: "%06X", rgb)
    }

    /// Elements and attributes in WordprocessingML's namespace, under the prefix the document
    /// gives it.
    private struct WordElements {
        let prefix: String

        func element(_ name: String, _ attributes: KeyValuePairs<String, String>) -> XMLElement {
            let element = XMLElement(name: "\(prefix):\(name)", uri: Namespace.word)
            for (key, value) in attributes {
                element.addAttribute(attribute(key, value))
            }
            return element
        }

        /// `parent`'s properties element (`pPr` or `rPr`), added as its first child if it has none.
        func properties(of parent: XMLElement, named name: String) -> XMLElement {
            if let existing = parent.elements(forLocalName: name, uri: Namespace.word).first {
                return existing
            }
            let added = element(name, [:])
            parent.insertChild(added, at: 0)
            return added
        }

        private func attribute(_ name: String, _ value: String) -> XMLNode {
            // `XMLNode.attribute(withName:uri:stringValue:)` returns `Any`; it's always an XMLNode.
            let node = XMLNode(kind: .attribute)
            node.name = "\(prefix):\(name)"
            node.stringValue = value
            return node
        }
    }

    // MARK: The package's parts list and relationships

    private static func addingStylesType(to data: Data) throws(Unexpected) -> Data {
        let xml = try parse(data)
        guard let root = xml.rootElement(), root.uri == Namespace.contentTypes else {
            throw Unexpected("no content types")
        }
        let override = XMLElement(name: "Override", uri: Namespace.contentTypes)
        override.setAttributesWith([
            "PartName": "/" + stylesPart,
            "ContentType": "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml",
        ])
        root.addChild(override)
        return serialized(xml)
    }

    private static func addingStylesRelationship(to data: Data) throws(Unexpected) -> Data {
        let xml = try parse(data)
        guard let root = xml.rootElement(), root.uri == Namespace.relationships else {
            throw Unexpected("no relationships")
        }
        let ids = Set(
            root.elements(forLocalName: "Relationship", uri: Namespace.relationships).compactMap {
                $0.attribute(forName: "Id")?.stringValue
            })
        guard let id = (1...ids.count + 1).lazy.map({ "rId\($0)" }).first(where: { !ids.contains($0) }) else {
            throw Unexpected("no relationship id free")
        }
        let relationship = XMLElement(name: "Relationship", uri: Namespace.relationships)
        relationship.setAttributesWith([
            "Id": id,
            "Type": "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles",
            "Target": "styles.xml",
        ])
        root.addChild(relationship)
        return serialized(xml)
    }

    // MARK: XML

    private static func parse(_ data: Data) throws(Unexpected) -> XMLDocument {
        do {
            return try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw Unexpected("not XML")
        }
    }

    private static func serialized(_ xml: XMLDocument) -> Data {
        xml.xmlData(options: [.nodePreserveWhitespace, .nodeCompactEmptyElement])
    }
}
