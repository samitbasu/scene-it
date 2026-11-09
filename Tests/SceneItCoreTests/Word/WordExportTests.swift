import AppKit
import Testing

@testable import SceneItCore

/// Export to Word's document (PLAN §10.2, ADR 0045), unzipped by macOS's own `unzip` and read as
/// XML: the title is Word's Heading 1, defined as Times New Roman 18 pt bold; the body is Times New
/// Roman 12 pt, double-spaced with a half-inch first-line indent; the formatting carries over and
/// the comments don't.
struct WordExportTests {
    static let comment = CommentID(rawValue: "01JC4K0000000000000000C001")

    static let scene = BookScene(
        id: SceneID(rawValue: "ferry"), modified: Timestamp("2026-11-03T10:15:00-08:00")!,
        title: "The ferry",
        body: [
            [
                Run("Mara took the "), Run("night", styles: [.bold]), Run(" ferry, "),
                Run("alone", styles: [.italic], color: .red),
                Run(" and ", comments: [comment]), Run("afraid", styles: [.strike], highlight: .green),
                Run("."),
            ],
            [],
            [Run("She ", highlight: .pink), Run("watched", styles: [.bold, .italic], highlight: .pink)],
            [], [],
        ],
        notes: [[Run("A private note.")]],
        comments: [
            Comment(
                id: comment, color: .blue, text: "Too quiet?",
                created: Timestamp("2026-11-03T10:15:00-08:00")!)
        ])

    /// The exported document's parts, read by macOS's `unzip`.
    struct Parts {
        let names: [String]
        let document: XMLDocument
        let styles: XMLDocument
        let contentTypes: XMLDocument
        let relationships: XMLDocument
        let raw: Data

        init(_ docx: Data) throws {
            #expect(try Unzip.test(docx), "macOS's unzip finds every part intact")
            func xml(_ name: String) throws -> XMLDocument {
                try XMLDocument(data: try Unzip.part(name, of: docx))
            }
            names = try Unzip.names(docx)
            document = try xml(WordPackage.documentPart)
            styles = try xml(WordPackage.stylesPart)
            contentTypes = try xml(WordPackage.contentTypesPart)
            relationships = try xml(WordPackage.documentRelationshipsPart)
            raw = docx
        }

        var paragraphs: [XMLElement] {
            (try? document.nodes(forXPath: "//*[local-name()='body']/*[local-name()='p']"))?.compactMap {
                $0 as? XMLElement
            } ?? []
        }
    }

    /// The `w:val` (or other) attribute of the WordprocessingML elements matching `path`.
    static func values(_ node: XMLNode, _ path: String, _ attribute: String = "val") -> [String] {
        let elements = (try? node.nodes(forXPath: path))?.compactMap { $0 as? XMLElement } ?? []
        return elements.compactMap { $0.attribute(forLocalName: attribute, uri: word)?.stringValue }
    }

    static let word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    static func text(_ paragraph: XMLElement) -> String {
        (try? paragraph.nodes(forXPath: ".//*[local-name()='t']"))?.compactMap(\.stringValue).joined() ?? ""
    }

    static func runs(_ paragraph: XMLElement) -> [XMLElement] {
        (try? paragraph.nodes(forXPath: "*[local-name()='r']"))?.compactMap { $0 as? XMLElement } ?? []
    }

    @Test func macOSsWriterLeavesOutStylesSpacingAndHighlights() throws {
        let paragraphs = WordParagraph.paragraphs(of: Self.scene)
        let text = WordExport.attributedString(paragraphs)
        let written = try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let archive = try ZipArchive(reading: written)
        let document = String(decoding: try #require(archive[WordPackage.documentPart]), as: UTF8.self)
        #expect(archive[WordPackage.stylesPart] == nil, "why the export adds styles.xml")
        #expect(!document.contains("w:shd") && !document.contains("w:highlight"), "why it shades highlights")
        #expect(!document.contains("w:line="), "why the styles carry the double spacing")
        #expect(!document.contains("pStyle"), "why it marks the title")
        #expect(
            document.contains("<w:color") && !document.contains("C62828"),
            "why it sets the palette's colours: macOS writes the red a shade darker")
    }

    @Test func theTitleIsHeading1DefinedAsTimesNewRoman18PointBold() throws {
        let parts = try Parts(WordExport.document(of: Self.scene))
        let paragraphs = parts.paragraphs
        try #require(paragraphs.count == 4, "precondition: the title and three body paragraphs")
        #expect(Self.values(paragraphs[0], "*[local-name()='pPr']/*[local-name()='pStyle']") == ["Heading1"])
        for body in paragraphs.dropFirst() {
            #expect(Self.values(body, ".//*[local-name()='pStyle']").isEmpty, "the body is the default style")
        }

        let heading = "//*[local-name()='style'][@*[local-name()='styleId']='Heading1']"
        try #require(
            try parts.styles.nodes(forXPath: heading).count == 1, "precondition: Heading1 is defined")
        #expect(Self.values(parts.styles, heading + "/*[local-name()='name']") == ["heading 1"])
        #expect(Self.values(parts.styles, heading + "/*[local-name()='basedOn']") == ["Normal"])
        #expect(
            Self.values(parts.styles, heading + "//*[local-name()='rFonts']", "ascii") == ["Times New Roman"])
        #expect(Self.values(parts.styles, heading + "//*[local-name()='sz']") == ["36"])
        #expect(
            try parts.styles.nodes(forXPath: heading + "/*[local-name()='rPr']/*[local-name()='b']").count
                == 1)
        #expect(Self.values(parts.styles, heading + "//*[local-name()='outlineLvl']") == ["0"])
        #expect(Self.values(parts.styles, heading + "//*[local-name()='spacing']", "line") == ["240"])
        #expect(Self.values(parts.styles, heading + "//*[local-name()='ind']", "firstLine") == ["0"])

        let titleRun = try #require(Self.runs(paragraphs[0]).first)
        #expect(Self.text(paragraphs[0]) == "The ferry")
        #expect(Self.values(titleRun, ".//*[local-name()='rFonts']", "ascii") == ["Times New Roman"])
        #expect(
            Self.values(titleRun, ".//*[local-name()='sz']") == ["36"], "the look doesn't depend on the style"
        )
        #expect(try titleRun.nodes(forXPath: ".//*[local-name()='b']").count == 1)
    }

    @Test func theBodyIsTimesNewRoman12PointDoubleSpacedWithAHalfInchIndent() throws {
        let parts = try Parts(WordExport.document(of: Self.scene))
        let normal = "//*[local-name()='style'][@*[local-name()='styleId']='Normal']"
        try #require(try parts.styles.nodes(forXPath: normal).count == 1, "precondition: Normal is defined")
        #expect(
            Self.values(parts.styles, normal, "default") == ["1"], "body paragraphs take it without a pStyle")
        #expect(Self.values(parts.styles, normal + "//*[local-name()='spacing']", "line") == ["480"])
        #expect(Self.values(parts.styles, normal + "//*[local-name()='spacing']", "lineRule") == ["auto"])
        #expect(Self.values(parts.styles, normal + "//*[local-name()='spacing']", "after") == ["0"])
        #expect(Self.values(parts.styles, normal + "//*[local-name()='ind']", "firstLine") == ["720"])
        #expect(
            Self.values(parts.styles, normal + "//*[local-name()='rFonts']", "ascii") == ["Times New Roman"])
        #expect(Self.values(parts.styles, normal + "//*[local-name()='sz']") == ["24"])

        let bodyRuns = parts.paragraphs.dropFirst().flatMap(Self.runs).filter { !Self.text($0).isEmpty }
        try #require(bodyRuns.count >= 8, "precondition: the body's runs")
        for run in bodyRuns {
            #expect(Self.values(run, ".//*[local-name()='rFonts']", "ascii") == ["Times New Roman"])
            #expect(Self.values(run, ".//*[local-name()='sz']") == ["24"])
        }
    }

    @Test func theFormattingCarriesOverAndTheCommentsDont() throws {
        let parts = try Parts(WordExport.document(of: Self.scene))
        let paragraphs = parts.paragraphs
        try #require(paragraphs.count == 4, "precondition: the title and three body paragraphs")
        #expect(
            paragraphs.map(Self.text) == [
                "The ferry", "Mara took the night ferry, alone and afraid.", "", "She watched",
            ], "the blank lines ending the scene aren't exported")
        func run(_ text: String) throws -> XMLElement {
            try #require(paragraphs.flatMap(Self.runs).first { Self.text($0) == text }, "a run \"\(text)\"")
        }
        func has(_ run: XMLElement, _ property: String) -> Bool {
            ((try? run.nodes(forXPath: "*[local-name()='rPr']/*[local-name()='\(property)']"))?.count ?? 0)
                > 0
        }
        let (night, alone, afraid, watched) = (
            try run("night"), try run("alone"), try run("afraid"), try run("watched")
        )
        #expect(has(night, "b") && !has(night, "i"))
        #expect(has(alone, "i"))
        #expect(Self.values(alone, ".//*[local-name()='color']") == ["C62828"], "the palette's red")
        #expect(has(afraid, "strike"))
        #expect(Self.values(afraid, ".//*[local-name()='shd']", "fill") == ["D9EDDA"], "green")
        #expect(Self.values(watched, ".//*[local-name()='shd']", "fill") == ["F8D5E7"], "pink")
        #expect(has(watched, "b") && has(watched, "i"))
        #expect(Self.values(try run("Mara took the "), ".//*[local-name()='shd']", "fill").isEmpty)

        let everything = String(
            decoding: try ZipArchive(reading: parts.raw).entries.map(\.bytes).reduce(Data(), +), as: UTF8.self
        )
        #expect(!everything.contains("Too quiet?"), "a comment's text isn't exported")
        #expect(!everything.contains("private note"), "nor are the notes")
        #expect(!parts.names.contains { $0.contains("comments") })
    }

    @Test func thePackageListsAndLinksTheStyles() throws {
        let parts = try Parts(WordExport.document(of: Self.scene))
        #expect(parts.names.contains("word/styles.xml"))
        let override = try parts.contentTypes.nodes(
            forXPath: "//*[local-name()='Override'][@PartName='/word/styles.xml']")
        #expect(
            (override.first as? XMLElement)?.attribute(forName: "ContentType")?.stringValue
                == "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml")
        let links = try parts.relationships.nodes(forXPath: "//*[local-name()='Relationship']").compactMap {
            $0 as? XMLElement
        }
        let styles = links.filter {
            $0.attribute(forName: "Type")?.stringValue
                == "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
        }
        #expect(styles.map { $0.attribute(forName: "Target")?.stringValue } == ["styles.xml"])
        let ids = links.compactMap { $0.attribute(forName: "Id")?.stringValue }
        #expect(Set(ids).count == ids.count, "every relationship id is unique")
    }

    @Test func macOSReadsTheRestyledDocument() throws {
        let read = try NSAttributedString(
            data: WordExport.document(of: Self.scene),
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(
            read.string == "The ferry\nMara took the night ferry, alone and afraid.\n\nShe watched\n",
            "its reader ends every paragraph")
    }

    @Test func anUntitledSceneHasNoHeading() throws {
        var scene = Self.scene
        scene.title = ""
        let parts = try Parts(WordExport.document(of: scene))
        #expect(parts.paragraphs.map(Self.text).first == "Mara took the night ferry, alone and afraid.")
        #expect(Self.values(parts.document, "//*[local-name()='pStyle']").isEmpty)
    }

    @Test(arguments: [SceneTitle(""), "Only a title"])
    func aSceneWithNoTextIsOneParagraph(_ title: SceneTitle) throws {
        let scene = BookScene(
            id: SceneID(rawValue: "empty"), modified: Self.scene.modified, title: title, body: [[], []])
        let parts = try Parts(WordExport.document(of: scene))
        #expect(parts.paragraphs.map(Self.text) == [title.text])
    }

    @Test func textMacOSWritesOtherwiseIsRefused() throws {
        let other = WordParagraph.paragraphs(of: Self.scene).map {
            WordParagraph(kind: $0.kind, runs: [Run("Other")])
        }
        let paragraphs = WordParagraph.paragraphs(of: Self.scene)
        let text = WordExport.attributedString(paragraphs)
        let written = try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        #expect(throws: WordExportFailure.conversion) { try WordPackage.restyled(written, other) }
        #expect(throws: WordExportFailure.conversion) {
            try WordPackage.restyled(written, Array(paragraphs.dropLast()))
        }
        #expect(throws: WordExportFailure.conversion) {
            try WordPackage.restyled(Data("not a zip".utf8), paragraphs)
        }
        var partly = paragraphs
        try #require(partly[1].runs.first == Run("Mara took the "), "precondition: a run macOS writes whole")
        partly[1] = WordParagraph(
            kind: .body, runs: [Run("Mara", highlight: .red), Run(" took the ")] + partly[1].runs.dropFirst())
        #expect(throws: WordExportFailure.conversion) { try WordPackage.restyled(written, partly) }
        #expect(throws: Never.self) { try WordPackage.restyled(written, paragraphs) }
    }
}
