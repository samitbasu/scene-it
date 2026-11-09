import AppKit
import Testing

@testable import SceneItCore

/// Export to Word's document (PLAN §10.2, ADR 0045, 0047), unzipped by macOS's own `unzip` and read
/// as XML: the title is Word's Heading 1, defined as Times New Roman 18 pt bold; the body is the
/// default style, Times New Roman 12 pt, double-spaced with a half-inch first-line indent; each run
/// carries its own formatting and the palette's colours; the comments and notes aren't there.
struct WordExportTests {
    static let comment = CommentID(rawValue: "01JC4K0000000000000000C001")
    static let modified = Timestamp("2026-11-03T10:15:00-08:00")!

    static let scene = BookScene(
        id: SceneID(rawValue: "ferry"), modified: modified, title: "The ferry",
        body: [
            [
                Run("Mara took the "), Run("night", styles: [.bold]), Run(" ferry, "),
                Run("alone", styles: [.italic], color: .red),
                Run(" and ", comments: [comment]), Run("afraid", styles: [.strike], highlight: .green),
                Run("."),
            ],
            [],
            [Run("She ", highlight: .pink), Run("watched", styles: [.bold, .italic], highlight: .pink)],
        ],
        notes: [[Run("A private note.")]],
        comments: [Comment(id: comment, color: .blue, text: "Too quiet?", created: modified)])

    static let word = WordDocument.Namespace.word

    /// The exported document's parts, read by macOS's `unzip`.
    struct Parts {
        let names: [String]
        let document: XMLDocument
        let styles: XMLDocument
        let contentTypes: XMLDocument
        let packageRelationships: XMLDocument
        let documentRelationships: XMLDocument
        let settings: XMLDocument
        let everything: String

        init(_ scene: BookScene) throws {
            let docx = try WordExport.document(of: scene)
            #expect(try Unzip.test(docx), "macOS's unzip finds every part intact")
            names = try Unzip.names(docx)
            let parts = try names.map { try Unzip.part($0, of: docx) }
            document = try XMLDocument(data: try Unzip.part("word/document.xml", of: docx))
            styles = try XMLDocument(data: try Unzip.part("word/styles.xml", of: docx))
            contentTypes = try XMLDocument(data: try Unzip.part("[Content_Types].xml", of: docx))
            packageRelationships = try XMLDocument(data: try Unzip.part("_rels/.rels", of: docx))
            documentRelationships = try XMLDocument(
                data: try Unzip.part("word/_rels/document.xml.rels", of: docx))
            settings = try XMLDocument(data: try Unzip.part("word/settings.xml", of: docx))
            everything = String(decoding: parts.reduce(Data(), +), as: UTF8.self)
        }

        var paragraphs: [XMLElement] {
            Self.elements(document, "//w:body/w:p")
        }

        static func elements(_ node: XMLNode, _ path: String) -> [XMLElement] {
            ((try? node.nodes(forXPath: WordExportTests.localNames(path))) ?? []).compactMap {
                $0 as? XMLElement
            }
        }
    }

    /// `path` with each `w:name` step written as `*[local-name()='name']`, since `XMLNode`'s XPath
    /// has no way to bind a prefix.
    static func localNames(_ path: String) -> String {
        path.replacing(/w:([A-Za-z]+)/) { "*[local-name()='\($0.1)']" }
    }

    /// The `w:` attribute `attribute` of the elements matching `path`.
    static func values(_ node: XMLNode, _ path: String, _ attribute: String = "val") -> [String] {
        Parts.elements(node, path).compactMap {
            $0.attribute(forLocalName: attribute, uri: word)?.stringValue
        }
    }

    static func text(_ paragraph: XMLElement) -> String {
        Parts.elements(paragraph, ".//w:t").compactMap(\.stringValue).joined()
    }

    static func runs(_ paragraph: XMLElement) -> [XMLElement] {
        Parts.elements(paragraph, "w:r")
    }

    /// The names of a run's properties, in order.
    static func properties(_ run: XMLElement) -> [String] {
        Parts.elements(run, "w:rPr/*").compactMap(\.localName)
    }

    @Test func thePackageHasExactlyTheMinimalParts() throws {
        let parts = try Parts(Self.scene)
        #expect(
            Set(parts.names) == [
                "[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels",
                "word/styles.xml", "word/settings.xml",
            ])
        let types = Parts.elements(parts.contentTypes, "//w:Override")
        #expect(
            Dictionary(
                uniqueKeysWithValues: types.map {
                    (
                        $0.attribute(forName: "PartName")?.stringValue ?? "",
                        $0.attribute(forName: "ContentType")?.stringValue ?? ""
                    )
                }) == [
                    "/word/document.xml":
                        "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
                    "/word/styles.xml":
                        "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml",
                    "/word/settings.xml":
                        "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml",
                ])
        let main = try #require(Parts.elements(parts.packageRelationships, "//w:Relationship").first)
        #expect(main.attribute(forName: "Target")?.stringValue == "word/document.xml")
        #expect(main.attribute(forName: "Type")?.stringValue?.hasSuffix("/officeDocument") == true)
        let links = Parts.elements(parts.documentRelationships, "//w:Relationship")
        #expect(
            links.map { $0.attribute(forName: "Target")?.stringValue } == ["styles.xml", "settings.xml"])
        #expect(
            links.map { $0.attribute(forName: "Type")?.stringValue?.split(separator: "/").last } == [
                "styles", "settings",
            ])
        let ids = links.compactMap { $0.attribute(forName: "Id")?.stringValue }
        #expect(Set(ids).count == 2, "each link has its own id")
    }

    @Test func wordDoesntOpenItInCompatibilityMode() throws {
        let parts = try Parts(Self.scene)
        let setting = "/w:settings/w:compat/w:compatSetting"
        try #require(
            Parts.elements(parts.settings, setting).count == 1, "precondition: one compatibility setting")
        #expect(Self.values(parts.settings, setting, "name") == ["compatibilityMode"])
        #expect(Self.values(parts.settings, setting, "uri") == ["http://schemas.microsoft.com/office/word"])
        #expect(Self.values(parts.settings, setting) == ["15"])
    }

    @Test(arguments: ["\u{0}", "\u{1}", "\u{8}", "\u{B}", "\u{1F}", "\u{FFFE}", "\u{FFFF}"])
    func aCharacterXMLCantHoldRefusesTheExport(_ character: String) throws {
        let run = Run(admitted: "a\(character)b", styles: [], color: nil, highlight: nil, comments: [])
        try #require(run.text.unicodeScalars.count == 3, "precondition: the character got past the policy")
        let scene = BookScene(id: SceneID(rawValue: "s"), modified: Self.modified, title: "T", body: [[run]])
        #expect(throws: WordExportFailure.unwritableCharacter) { try WordExport.document(of: scene) }
        #expect(WordExportWording.notice(for: .unwritableCharacter).message.contains("character"))
    }

    @Test func xmlsCharacterRangeIsExact() {
        let allowed: [UInt32] = [0x9, 0xA, 0xD, 0x20, 0xD7FF, 0xE000, 0xFFFD, 0x1_0000, 0x10_FFFF]
        let refused: [UInt32] = [0x0, 0x8, 0xB, 0xC, 0xE, 0x1F, 0xFFFE, 0xFFFF]
        #expect(allowed.compactMap(Unicode.Scalar.init).allSatisfy(WordDocument.isXMLCharacter))
        #expect(!refused.compactMap(Unicode.Scalar.init).contains(where: WordDocument.isXMLCharacter))
        #expect(refused.compactMap(Unicode.Scalar.init).count == refused.count, "precondition: all scalars")
    }

    @Test func theTitleIsHeading1DefinedAsTimesNewRoman18PointBold() throws {
        let parts = try Parts(Self.scene)
        let paragraphs = parts.paragraphs
        try #require(paragraphs.count == 4, "precondition: the title and three body paragraphs")
        #expect(Self.values(paragraphs[0], "w:pPr/w:pStyle") == ["Heading1"])
        #expect(Self.text(paragraphs[0]) == "The ferry")
        #expect(
            Self.properties(try #require(Self.runs(paragraphs[0]).first)).isEmpty, "the style does it all")
        for body in paragraphs.dropFirst() {
            #expect(Parts.elements(body, "w:pPr").isEmpty, "the body takes the default style")
        }

        let heading = "//w:style[@*[local-name()='styleId']='Heading1']"
        try #require(Parts.elements(parts.styles, heading).count == 1, "precondition: Heading1 is defined")
        #expect(Self.values(parts.styles, heading + "/w:name") == ["heading 1"])
        #expect(Self.values(parts.styles, heading + "/w:basedOn") == ["Normal"])
        #expect(Self.values(parts.styles, heading + "/w:rPr/w:rFonts", "ascii") == ["Times New Roman"])
        #expect(Self.values(parts.styles, heading + "/w:rPr/w:sz") == ["36"])
        #expect(Parts.elements(parts.styles, heading + "/w:rPr/w:b").count == 1)
        #expect(Self.values(parts.styles, heading + "/w:rPr/w:color") == ["000000"])
        #expect(Self.values(parts.styles, heading + "/w:pPr/w:outlineLvl") == ["0"])
        #expect(Self.values(parts.styles, heading + "/w:pPr/w:spacing", "line") == ["240"])
        #expect(Self.values(parts.styles, heading + "/w:pPr/w:ind", "firstLine") == ["0"])
    }

    @Test func theBodyIsTimesNewRoman12PointDoubleSpacedWithAHalfInchIndent() throws {
        let parts = try Parts(Self.scene)
        let normal = "//w:style[@*[local-name()='styleId']='Normal']"
        try #require(Parts.elements(parts.styles, normal).count == 1, "precondition: Normal is defined")
        #expect(Self.values(parts.styles, normal, "default") == ["1"], "paragraphs without a pStyle take it")
        #expect(Self.values(parts.styles, normal + "/w:pPr/w:spacing", "line") == ["480"])
        #expect(Self.values(parts.styles, normal + "/w:pPr/w:spacing", "lineRule") == ["auto"])
        #expect(Self.values(parts.styles, normal + "/w:pPr/w:spacing", "after") == ["0"])
        #expect(Self.values(parts.styles, normal + "/w:pPr/w:ind", "firstLine") == ["720"])
        #expect(Self.values(parts.styles, normal + "/w:rPr/w:rFonts", "ascii") == ["Times New Roman"])
        #expect(Self.values(parts.styles, normal + "/w:rPr/w:sz") == ["24"])
    }

    @Test func onlyStandardNamesAreWritten() throws {
        let parts = try Parts(Self.scene)
        for nonstandard in ["sz-cs", "first-line"] {
            #expect(!parts.everything.contains(nonstandard), "Word 2003's \(nonstandard)")
        }
    }

    @Test func theFormattingCarriesOverAndTheCommentsDont() throws {
        let parts = try Parts(Self.scene)
        let paragraphs = parts.paragraphs
        #expect(
            paragraphs.map(Self.text) == [
                "The ferry", "Mara took the night ferry, alone and afraid.", "", "She watched",
            ])
        func run(_ text: String) throws -> XMLElement {
            try #require(paragraphs.flatMap(Self.runs).first { Self.text($0) == text }, "a run \"\(text)\"")
        }
        #expect(Self.properties(try run("Mara took the ")).isEmpty)
        #expect(Self.properties(try run("night")) == ["b"])
        #expect(Self.properties(try run("alone")) == ["i", "color"])
        #expect(Self.values(try run("alone"), "w:rPr/w:color") == ["C62828"], "the palette's red, exactly")
        #expect(Self.properties(try run("afraid")) == ["strike", "shd"])
        #expect(Self.values(try run("afraid"), "w:rPr/w:shd", "fill") == ["D9EDDA"], "the palette's green")
        #expect(Self.properties(try run("watched")) == ["b", "i", "shd"], "in the schema's order")
        #expect(Self.values(try run("watched"), "w:rPr/w:shd", "fill") == ["F8D5E7"], "the palette's pink")
        #expect(Self.properties(try run(" and ")).isEmpty, "the commented words are plain text")

        #expect(!parts.everything.contains("Too quiet?"), "a comment's text isn't exported")
        #expect(!parts.everything.contains("private note"), "nor are the notes")
    }

    @Test func adjacentRunsDifferingOnlyInColourStayApart() throws {
        var scene = Self.scene
        scene.body = [[Run("red", color: .red), Run("blue", color: .blue), Run("plain")]]
        let runs = try Parts(scene).paragraphs.dropFirst().flatMap(Self.runs)
        #expect(runs.map(Self.text) == ["red", "blue", "plain"])
        #expect(runs.map { Self.values($0, "w:rPr/w:color") } == [["C62828"], ["1E5BC6"], []])
    }

    @Test func adjacentRunsDifferingOnlyInHighlightStayApart() throws {
        var scene = Self.scene
        scene.body = [[Run("gray", highlight: .gray), Run("purple", highlight: .purple), Run("none")]]
        let runs = try Parts(scene).paragraphs.dropFirst().flatMap(Self.runs)
        #expect(runs.map(Self.text) == ["gray", "purple", "none"])
        #expect(runs.map { Self.values($0, "w:rPr/w:shd", "fill") } == [["E6E6E6"], ["E9DDF7"], []])
    }

    @Test func anUntitledSceneHasNoHeading() throws {
        var scene = Self.scene
        scene.title = ""
        let parts = try Parts(scene)
        #expect(parts.paragraphs.map(Self.text).first == "Mara took the night ferry, alone and afraid.")
        #expect(Self.values(parts.document, "//w:pStyle").isEmpty)
        #expect(parts.paragraphs.count == 3)
    }

    @Test(arguments: [SceneTitle(""), "Only a title"])
    func aSceneWithNoTextIsOneParagraph(_ title: SceneTitle) throws {
        let scene = BookScene(id: SceneID(rawValue: "empty"), modified: Self.modified, title: title)
        #expect(try Parts(scene).paragraphs.map(Self.text) == [title.text])
    }

    @Test func blankLinesAreKeptAsEmptyParagraphs() throws {
        var scene = Self.scene
        scene.body = [[], [Run("Middle.")], [], []]
        #expect(try Parts(scene).paragraphs.map(Self.text) == ["The ferry", "", "Middle.", "", ""])
    }

    @Test func everyCharacterThePolicyAllowsSurvivesTheXML() throws {
        let allowed = String(String.UnicodeScalarView((0x20...0x7E).compactMap(Unicode.Scalar.init)))
        try #require(
            allowed.unicodeScalars.allSatisfy(CharacterPolicy.isAllowed) && allowed.contains("<")
                && allowed.contains("&") && allowed.contains("'"),
            "precondition: printable ASCII, the markup characters among it")
        var scene = Self.scene
        scene.title = SceneTitle(allowed)
        scene.body = [[Run(allowed, styles: [.bold])]]
        try #require(scene.title.text == allowed, "precondition: the title keeps every character")
        #expect(try Parts(scene).paragraphs.map(Self.text) == [allowed, allowed])
        #expect(try WordDocument.escaped("<a & 'b'>") == "&lt;a &amp; &apos;b&apos;&gt;")
    }

    @Test func macOSReadsTheDocument() throws {
        let read = try NSAttributedString(
            data: WordExport.document(of: Self.scene),
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(
            read.string.hasPrefix("The ferry\nMara took the night ferry, alone and afraid.\n\nShe watched"))
    }
}
