import AppKit
import CryptoKit
import Testing

@testable import SceneItCore

/// Export to Word with its comments (ADR 0048), read back with macOS's `unzip` and XPath: each
/// anchored comment is a Word comment in `word/comments.xml`, its range wrapping exactly the text
/// it covers, overlapping, nested or across paragraphs as the scene's do; without them, the
/// document is byte for byte what it was before comments could be exported.
struct WordCommentsTests {
    typealias Parts = WordExportTests.Parts

    static let author = CommentAuthor(fullName: "Mara Lind")

    static func comment(_ number: Int, _ text: String) -> SceneItCore::Comment {
        SceneItCore::Comment(
            id: CommentID(rawValue: "01JC4K0000000000000000C0\(String(format: "%02d", number))"),
            color: .blue,
            text: text, created: Timestamp("2026-11-03T10:\(String(format: "%02d", number)):00-08:00")!)
    }

    static let schedule = comment(1, "Check the ferry schedule.")
    static let lights = comment(2, "Too pretty?")
    static let gone = comment(3, "Say what goes out.")
    static let span = comment(4, "Carry this over the break.")
    static let detached = comment(5, "Its text was deleted.")

    /// "The ferry left at dawn" (schedule), "harbor lights go out" (lights) overlapping "lights go
    /// out one by one" (gone), and "behind her." running into the next paragraph's "Nobody met
    /// her" (span); one comment is detached.
    static let scene = BookScene(
        id: SceneID(rawValue: "ferry"), modified: WordExportTests.modified, title: "The ferry",
        body: [
            [
                Run("The ferry left at dawn", comments: [schedule.id]),
                Run(", and Mara watched the "),
                Run("harbor ", comments: [lights.id]),
                Run("lights go out", styles: [.italic], comments: [lights.id, gone.id]),
                Run(" one by one", comments: [gone.id]),
                Run(" "),
                Run("behind her.", comments: [span.id]),
            ],
            [Run("Nobody met her", comments: [span.id]), Run(" at the landing.")],
        ],
        comments: [span, gone, detached, lights, schedule])

    static func parts(_ scene: BookScene = scene) throws -> Parts {
        try Parts(scene, comments: .included(by: author))
    }

    static func attribute(_ element: XMLElement, _ name: String) -> String? {
        element.attribute(forLocalName: name, uri: WordExportTests.word)?.stringValue
    }

    /// The text each comment's range holds, by Word id, read in document order: a paragraph break
    /// inside a range is a line break.
    static func anchored(_ document: XMLDocument) -> [Int: String] {
        let path =
            "//*[local-name()='p' or local-name()='t' or local-name()='commentRangeStart'"
            + " or local-name()='commentRangeEnd']"
        var open: Set<Int> = []
        var started = false
        var texts: [Int: String] = [:]
        for case let element as XMLElement in (try? document.nodes(forXPath: path)) ?? [] {
            let id = attribute(element, "id").flatMap(Int.init)
            switch element.localName {
            case "p":
                if started { for id in open { texts[id, default: ""] += "\n" } }
                started = true
            case "t": for id in open { texts[id, default: ""] += element.stringValue ?? "" }
            case "commentRangeStart": if let id { open.insert(id) }
            case "commentRangeEnd": if let id { open.remove(id) }
            default: break
            }
        }
        return texts
    }

    /// The comment marks' kinds and ids in document order: "s0" a range's start, "e0" its end,
    /// "r0" its reference.
    static func marks(_ document: XMLDocument) -> [String] {
        let path =
            "//*[local-name()='commentRangeStart' or local-name()='commentRangeEnd'"
            + " or local-name()='commentReference']"
        return ((try? document.nodes(forXPath: path)) ?? []).compactMap { node in
            guard let element = node as? XMLElement, let id = attribute(element, "id") else { return nil }
            let kind =
                switch element.localName {
                case "commentRangeStart": "s"
                case "commentRangeEnd": "e"
                default: "r"
                }
            return kind + id
        }
    }

    static func comments(_ parts: Parts) throws -> [XMLElement] {
        let xml = try #require(parts.comments, "precondition: there's a comments part")
        return Parts.elements(xml, "/w:comments/w:comment")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A golden test: the SHA-256 of the unticked document for `WordExportTests.scene` and for a
    /// `--` and a `...` split by a comment's edges, which ticking Include comments must not
    /// change. A change that alters the document on purpose regenerates these digests, and the
    /// review checks the new document. (They were first taken from the export as it was before
    /// comments could be exported.)
    @Test func withoutCommentsTheBytesAreUnchanged() throws {
        var split = WordExportTests.scene
        split.body = [
            [Run("Wait -"), Run("- no", comments: [WordExportTests.comment]), Run(".."), Run(". Gone.")]
        ]
        try #require(!WordExportTests.scene.comments.isEmpty, "precondition: the scene has a comment")
        #expect(
            Self.sha256(try WordExport.document(of: WordExportTests.scene, comments: .omitted))
                == "8833dc29c9f0e6a6ab0b33272111860a820dfc24afd276571345ff9d382c4ab6")
        #expect(
            Self.sha256(try WordExport.document(of: split, comments: .omitted))
                == "ec33049c8880bad6450155a8b212b3ea5634b1d8c330f7c0e3afe971730e706d")
        let parts = try Parts(Self.scene)
        #expect(parts.comments == nil && !parts.everything.contains("comment"))
    }

    @Test func thePackageGainsTheCommentsPartItsTypeAndItsLink() throws {
        let parts = try Self.parts()
        #expect(parts.names.last == "word/comments.xml")
        let types = Parts.elements(parts.contentTypes, "//w:Override").filter {
            $0.attribute(forName: "PartName")?.stringValue == "/word/comments.xml"
        }
        #expect(
            types.compactMap { $0.attribute(forName: "ContentType")?.stringValue } == [
                "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"
            ])
        let links = Parts.elements(parts.documentRelationships, "//w:Relationship")
        #expect(
            links.map { $0.attribute(forName: "Target")?.stringValue } == [
                "styles.xml", "settings.xml", "comments.xml",
            ])
        #expect(
            links.last?.attribute(forName: "Type")?.stringValue
                == "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments")
        #expect(Set(links.compactMap { $0.attribute(forName: "Id")?.stringValue }).count == 3)

        let style = "//w:style[@*[local-name()='styleId']='CommentText']"
        try #require(Parts.elements(parts.styles, style).count == 1, "precondition: Word's comment style")
        #expect(WordExportTests.values(parts.styles, style + "/w:name") == ["annotation text"])
        #expect(WordExportTests.values(parts.styles, style + "/w:pPr/w:spacing", "line") == ["240"])
        #expect(WordExportTests.values(parts.styles, style + "/w:pPr/w:ind", "firstLine") == ["0"])
        #expect(WordExportTests.values(parts.styles, style + "/w:rPr/w:sz") == ["20"])
    }

    /// The anchored comments, in the order their text starts; the detached one isn't there.
    @Test func eachAnchoredCommentIsAWordCommentWithItsText() throws {
        let parts = try Self.parts()
        let comments = try Self.comments(parts)
        #expect(comments.map { Self.attribute($0, "id") } == ["0", "1", "2", "3"])
        #expect(
            comments.map { Parts.elements($0, ".//w:t").compactMap(\.stringValue).joined() } == [
                Self.schedule.text, Self.lights.text, Self.gone.text, Self.span.text,
            ])
        #expect(!parts.everything.contains(Self.detached.text), "a detached comment has no text to anchor to")
        #expect(comments.map { Self.attribute($0, "author") } == Array(repeating: "Mara Lind", count: 4))
        #expect(comments.map { Self.attribute($0, "initials") } == Array(repeating: "ML", count: 4))
        #expect(
            comments.map { Self.attribute($0, "date") } == [
                "2026-11-03T10:01:00", "2026-11-03T10:02:00", "2026-11-03T10:03:00", "2026-11-03T10:04:00",
            ], "the comment's creation, as the writer's clock showed it")
        for comment in comments {
            #expect(WordExportTests.values(comment, "w:p/w:pPr/w:pStyle") == ["CommentText"])
            #expect(Parts.elements(comment, "w:p[1]/w:r[1]/w:annotationRef").count == 1)
            #expect(Parts.elements(comment, ".//w:color").isEmpty, "Word colours comments by author")
        }
    }

    @Test func eachRangeWrapsExactlyItsText() throws {
        let anchored = Self.anchored(try Self.parts().document)
        #expect(
            anchored == [
                0: "The ferry left at dawn", 1: "harbor lights go out", 2: "lights go out one by one",
                3: "behind her.\nNobody met her",
            ])
    }

    /// Each range ends with a reference to its comment, just after its end.
    @Test func eachEndIsFollowedByItsReference() throws {
        let marks = Self.marks(try Self.parts().document)
        #expect(marks.filter { $0.hasPrefix("r") } == ["r0", "r1", "r2", "r3"])
        for (index, mark) in marks.enumerated() where mark.hasPrefix("e") {
            #expect(marks[index + 1] == "r" + mark.dropFirst())
        }
    }

    /// "harbor lights go out" and "lights go out one by one" overlap: the second starts inside
    /// the first and ends after it, so neither range is inside the other.
    @Test func overlappingCommentsOverlap() throws {
        let parts = try Self.parts()
        let marks = Self.marks(parts.document).filter { $0.dropFirst() == "1" || $0.dropFirst() == "2" }
        #expect(marks == ["s1", "s2", "e1", "r1", "e2", "r2"])
        let shared = try #require(
            WordExportTests.runs(parts.paragraphs[1]).first { WordExportTests.text($0) == "lights go out" },
            "precondition: the shared words are one run")
        #expect(WordExportTests.properties(shared) == ["i"])
    }

    /// A comment inside another, and two over the same words, close in the reverse of the order
    /// they opened.
    @Test func nestedCommentsNest() throws {
        var scene = Self.scene
        scene.body = [
            [
                Run("She had ", comments: [Self.schedule.id]),
                Run("packed", comments: [Self.schedule.id, Self.lights.id]),
                Run(" in the dark", comments: [Self.schedule.id]),
                Run(" by feel", comments: [Self.gone.id, Self.span.id]), Run("."),
            ]
        ]
        let parts = try Self.parts(scene)
        #expect(
            Self.anchored(parts.document) == [
                0: "She had packed in the dark", 1: "packed", 2: " by feel", 3: " by feel",
            ])
        #expect(
            Self.marks(parts.document) == [
                "s0", "s1", "e1", "r1", "e0", "r0", "s2", "s3", "e3", "r3", "e2", "r2",
            ])
    }

    /// Two ranges starting on the same words open longest first, so the shorter nests inside the
    /// longer, whichever has the lower id.
    @Test func rangesStartingTogetherOpenLongestFirst() throws {
        var scene = Self.scene
        scene.comments = [Self.schedule, Self.lights]
        scene.body = [
            [
                Run("She had ", comments: [Self.schedule.id, Self.lights.id]),
                Run("packed", comments: [Self.lights.id]), Run("."),
            ]
        ]
        let parts = try Self.parts(scene)
        let anchored = Self.anchored(parts.document)
        try #require(anchored == [0: "She had ", 1: "She had packed"], "precondition: the shorter has id 0")
        #expect(Self.marks(parts.document) == ["s1", "s0", "e0", "r0", "e1", "r1"])
    }

    /// The marks' runs, in the document and in the balloons, are in Word's "annotation reference"
    /// style, 8 pt, which the styles define.
    @Test func theMarksAreInWordsReferenceStyle() throws {
        let parts = try Self.parts()
        let reference = "//w:r[w:commentReference]"
        let references = Parts.elements(parts.document, reference)
        try #require(references.count == 4, "precondition: a reference to each comment")
        #expect(
            WordExportTests.values(parts.document, reference + "/w:rPr/w:rStyle")
                == Array(repeating: "CommentReference", count: 4))
        let xml = try #require(parts.comments)
        let marks = "//w:r[w:annotationRef]"
        try #require(Parts.elements(xml, marks).count == 4, "precondition: a mark in each balloon")
        #expect(
            WordExportTests.values(xml, marks + "/w:rPr/w:rStyle")
                == Array(repeating: "CommentReference", count: 4))

        let style = "//w:style[@*[local-name()='styleId']='CommentReference']"
        try #require(Parts.elements(parts.styles, style).count == 1, "precondition: the style is defined")
        #expect(WordExportTests.values(parts.styles, style, "type") == ["character"])
        #expect(WordExportTests.values(parts.styles, style + "/w:name") == ["annotation reference"])
        #expect(WordExportTests.values(parts.styles, style + "/w:rPr/w:sz") == ["16"])
    }

    @Test(arguments: [WordCommentChoice.omit, .include])
    func theCheckboxShowsTheChoiceAndSetsIt(_ choice: WordCommentChoice) {
        #expect(WordCommentChoice(ticked: choice.isTicked) == choice)
        #expect(WordCommentChoice(ticked: false) == .omit && WordCommentChoice(ticked: true) == .include)
        #expect(choice.isTicked == (choice == .include))
        #expect(
            choice.comments(by: Self.author) == (choice == .include ? .included(by: Self.author) : .omitted))
    }

    /// macOS's own Office Open XML importer reads a document with comments.
    @Test func macOSReadsADocumentWithComments() throws {
        let read = try NSAttributedString(
            data: WordExport.document(of: Self.scene, comments: .included(by: Self.author)),
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(
            read.string.hasPrefix(
                "The ferry\nThe ferry left at dawn, and Mara watched the harbor lights go out one by one behind her."
                    + "\nNobody met her at the landing."))
    }

    @Test func aCommentCanSpanParagraphs() throws {
        let parts = try Self.parts()
        let paragraphs = parts.paragraphs
        try #require(paragraphs.count == 3, "precondition: the title and two paragraphs")
        func marks(_ paragraph: XMLElement) -> [String] {
            Parts.elements(paragraph, "w:commentRangeStart | w:commentRangeEnd").compactMap { element in
                Self.attribute(element, "id").map {
                    (element.localName == "commentRangeStart" ? "s" : "e") + $0
                }
            }
        }
        #expect(marks(paragraphs[1]).contains("s3") && !marks(paragraphs[1]).contains("e3"))
        #expect(marks(paragraphs[2]) == ["e3"])
        #expect(Self.anchored(parts.document)[3] == "behind her.\nNobody met her")
    }

    @Test func aCommentsTextIsEscapedAndSmartenedAndKeepsItsLines() throws {
        var scene = Self.scene
        scene.comments = [
            SceneItCore::Comment(
                id: Self.schedule.id, color: .red, text: "<b> & \"so\" -- it's\n\nsecond line",
                created: Self.schedule.created)
        ]
        let parts = try Parts(scene, comments: .included(by: CommentAuthor(fullName: "<Mara> & \"Co\"")))
        let comment = try #require(try Self.comments(parts).first)
        let lines = Parts.elements(comment, "w:p").map {
            Parts.elements($0, ".//w:t").compactMap(\.stringValue).joined()
        }
        #expect(lines == ["<b> & \u{201C}so\u{201D} \u{2014} it\u{2019}s", "", "second line"])
        #expect(Self.attribute(comment, "author") == "<Mara> & \"Co\"")
        #expect(Self.attribute(comment, "initials") == "<&\"")
        #expect(parts.everything.contains("&lt;b&gt; &amp; "))
    }

    @Test(arguments: ["", "   ", "\n"])
    func anAccountWithoutANameAuthorsAsSceneIt(_ fullName: String) throws {
        let author = CommentAuthor(fullName: fullName)
        #expect(author == CommentAuthor(fullName: "Scene It"))
        #expect(author.name == WordExportWording.unnamedAuthor && author.initials == "SI")
        let parts = try Parts(Self.scene, comments: .included(by: author))
        #expect(try Self.comments(parts).map { Self.attribute($0, "author") }.allSatisfy { $0 == "Scene It" })
    }

    @Test func aNamesInitialsAreItsWordsFirstLetters() {
        let author = CommentAuthor(fullName: "  samit   basu ")
        #expect(author.name == "samit basu")
        #expect(author.initials == "SB")
        #expect(CommentAuthor(fullName: "Cher").initials == "C")
    }

    @Test func anAuthorsNameXMLCantHoldRefusesTheExport() {
        #expect(throws: WordExportFailure.unwritableCharacter) {
            try WordExport.document(
                of: Self.scene, comments: .included(by: CommentAuthor(fullName: "Ma\u{1}ra")))
        }
    }

    /// With comments, a comment's edge splits the runs, and a `--` or `...` across it stays as it
    /// is; inside one run, or across runs that differ in neither look nor comments, it's still
    /// smartened.
    @Test func aDashSplitByACommentsEdgeStaysTwoHyphens() throws {
        var scene = Self.scene
        scene.body = [
            [Run("Wait -"), Run("- no", comments: [Self.schedule.id]), Run(".."), Run(". Gone -- now.")]
        ]
        let paragraph = try #require(try Self.parts(scene).paragraphs.last)
        #expect(
            Parts.elements(paragraph, "w:r/w:t").compactMap(\.stringValue) == [
                "Wait -", "- no", "\u{2026} Gone \u{2014} now.",
            ])
    }

    @Test func noCommentsMeansAnEmptyCommentsPart() throws {
        var scene = Self.scene
        scene.comments = [Self.detached]
        scene.body = scene.body.map(\.uncommented)
        let parts = try Self.parts(scene)
        #expect(try Self.comments(parts).isEmpty)
        #expect(Self.marks(parts.document).isEmpty)
    }
}
