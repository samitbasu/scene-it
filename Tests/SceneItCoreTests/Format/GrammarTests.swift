import Foundation
import Testing

@testable import SceneItCore

/// Book format §1–§5, rule by rule: every table row that has an input and a result.
@Suite struct FileGrammarTests {
    // MARK: §1.3 Trimming

    @Test(arguments: [
        ("   indented", "indented"),
        ("trailing   ", "trailing"),
        (#"escaped\ "#, #"escaped\ "#),
        (#"escaped\    "#, #"escaped\ "#),
        (#"even\\  "#, #"even\\"#),
        (#"stripped\"#, #"stripped\ "#),
        (#"literal\\"#, #"literal\\"#),
        ("", ""),
        ("     ", ""),
    ])
    func linesAreTrimmed(raw: String, trimmed: String) {
        #expect(Lexical.trim(Array(raw.utf8)[...]) == Array(trimmed.utf8))
    }

    // MARK: §1.4 Headings

    @Test(arguments: [
        ("## Title", LineKind.heading(level: 2, name: Array("Title".utf8)[...])),
        ("##", .heading(level: 2, name: [])),
        ("######", .heading(level: 6, name: [])),
        ("#hashtag", .text),
        ("####### x", .text),
        ("\\## x", .text),
        ("", .blank),
    ])
    func headingShapedLines(line: String, kind: LineKind) {
        #expect(Lexical.kind(of: Array(line.utf8)) == kind)
    }

    @Test func unknownHeadingsAreLineEntriesAndLeaveTheSectionAlone() throws {
        let scene = try onlyScene(file(scene: "Before.\n### Note\nAfter.\n\n#### Part 2\n\n# Act 1\n\nLast."))
        #expect(scene.body.map(\.text) == ["Before.", "After.", "Last."])
        #expect(
            scene.errors == [
                ErrorEntry(.line, "### Note"), ErrorEntry(.line, "#### Part 2"), ErrorEntry(.line, "# Act 1"),
            ])
    }

    @Test func aKnownSubsectionHeadingInTheBodyIsASubsection() throws {
        let scene = try onlyScene(file(scene: "Body.\n### NOTES\nNow notes."))
        #expect(scene.body.map(\.text) == ["Body."])
        #expect(scene.notes.map(\.text) == ["Now notes."])
    }

    @Test func notesOutsideAScene() {
        let book = parse("---\ntitle: T\nformat: 2\n---\n\n### Notes\nstray\n").book
        #expect(book.errors == [ErrorEntry(.line, "### Notes"), ErrorEntry(.line, "stray")])
    }

    // MARK: §1.5 Front matter

    @Test func frontMatterDefaultsAndNotices() {
        let empty = parse(Data()).book
        #expect(
            empty
                == Book(
                    title: "Untitled",
                    errors: [RepairNotice.missingTitle.entry, RepairNotice.missingFormat.entry]))
        #expect(
            empty.errors.map(\.payload) == [
                "The book had no title, so it was called \"Untitled\".",
                "The file had no format line; it was read as format 2.",
            ])
    }

    @Test func frontMatterLines() {
        let parsed = parse(
            "\n\n---\nTITLE: A \\| b\\, c\\n\nformat: 02\ntitle: second\nauthor: me\nnot a key\n\nformat x: 1\n---\n"
        )
        #expect(parsed.book.title == "A | b, c\n")
        #expect(parsed.declaredFormat == FormatVersion(2))
        #expect(
            parsed.book.errors == [
                ErrorEntry(.frontMatter, "title: second"), ErrorEntry(.frontMatter, "author: me"),
                ErrorEntry(.frontMatter, "not a key"), ErrorEntry(.frontMatter, "format x: 1"),
            ])
    }

    @Test func anEmptyTitleIsATitle() {
        let book = parse("---\ntitle:\nformat: 2\n---\n").book
        #expect(book == Book(title: ""))
        #expect(serialized(book) == "---\ntitle:\nformat: 2\n---\n")
    }

    @Test func aBadFormatIsAnEntryAndThenMissing() {
        let parsed = parse("---\ntitle: T\nformat: two\n---\n")
        #expect(parsed.declaredFormat == nil)
        #expect(
            parsed.book.errors == [ErrorEntry(.frontMatter, "format: two"), RepairNotice.missingFormat.entry])
    }

    @Test func aNewerFormatIsReadWithANotice() {
        let parsed = parse(
            "---\ntitle: T\nformat: 3\n---\n\n## S\nid: a\nmodified: 2026-01-01T00:00:00Z\n\nText.\n")
        #expect(parsed.declaredFormat == FormatVersion(3))
        #expect(parsed.isNewerThanSupported)
        #expect(parsed.book.errors == [RepairNotice.otherFormat(3).entry])
        #expect(
            parsed.book.errors[0].payload
                == "The file says format 3; this version of Scene It reads format 2.")
        #expect(parsed.book.scenes[0].body.map(\.text) == ["Text."])
        #expect(!parse("---\ntitle: T\nformat: 1\n---\n").isNewerThanSupported)
    }

    @Test func frontMatterNotClosedEndsAtAHeading() {
        let book = parse("---\ntitle: T\nformat: 2\n## S\nid: a\nmodified: 2026-01-01T00:00:00Z\n").book
        #expect(book.title == "T")
        #expect(book.errorEntries.joined().isEmpty)
        #expect(book.scenes.count == 1)
        #expect(serialized(book).hasPrefix("---\ntitle: T\nformat: 2\n---\n\n## S\n"))
    }

    @Test func noFrontMatterReadsTheFileAsThePreamble() {
        let book = parse("Hello\n## S\nid: a\nmodified: 2026-01-01T00:00:00Z\n").book
        #expect(book.title == "Untitled")
        #expect(
            book.errors == [
                ErrorEntry(.line, "Hello"), RepairNotice.missingTitle.entry, RepairNotice.missingFormat.entry,
            ])
    }

    @Test func aV1JSONFileIsAllLineEntries() {
        let book = parse("{\n  \"format\" : 1,\n  \"title\" : \"Old\"\n}\n").book
        #expect(book.scenes.isEmpty)
        #expect(
            Array(book.errors.prefix(4))
                == ["{", "\"format\" : 1,", "\"title\" : \"Old\"", "}"].map { ErrorEntry(.line, $0) })
    }

    // MARK: §1.6–§1.8 Preamble, Boneyard

    @Test func theBoneyard() {
        let text =
            "---\ntitle: T\nformat: 2\n---\n\n## A\nid: a\nmodified: 2026-01-01T00:00:00Z\n\n# boneyard\n\n"
            + "between\n\n### Unparsed\n- [line] kept\n\n## B\nid: b\nmodified: 2026-01-01T00:00:00Z\n\n# Boneyard\n\n"
            + "## C\nid: c\nmodified: 2026-01-01T00:00:00Z\n"
        let book = parse(text).book
        #expect(book.scenes.map(\.id.rawValue) == ["a"])
        #expect(book.boneyard.map(\.id.rawValue) == ["b", "c"])
        #expect(book.errors == [ErrorEntry(.line, "between"), ErrorEntry(.line, "kept")])
        #expect(book.boneyard[0].errors == [ErrorEntry(.line, "# Boneyard")], "a second Boneyard heading")
    }

    @Test func anEmptyBoneyardIsNotWritten() {
        let book = parse("---\ntitle: T\nformat: 2\n---\n\n# Boneyard\n").book
        #expect(serialized(book) == "---\ntitle: T\nformat: 2\n---\n")
    }

    // MARK: §2 Scenes

    @Test(arguments: [
        ("## The *ferry*", "The ferry", "## The ferry"),
        ("##", "", "##"),
        ("## ", "", "##"),
        ("##    spaced  ", "spaced", "## spaced"),
        (#"## \ edges\ "#, " edges ", #"## \ edges\ "#),
        ("## a * b and_c ~ d", "a * b and_c ~ d", #"## a \* b and\_c \~ d"#),
        ("## He said **wow.", "He said **wow.", #"## He said \*\*wow."#),
        (#"## C:\logs"#, #"C:\logs"#, #"## C:\\logs"#),
        ("## #7 <br>", "#7 <br>", "## #7 <br>"),
    ])
    func titles(heading: String, title: String, written: String) throws {
        let scene = try onlyScene(
            "---\ntitle: T\nformat: 2\n---\n\n\(heading)\nid: a\nmodified: 2026-01-01T00:00:00Z\n")
        #expect(scene.title.text == title)
        #expect(serialized(Book(title: "T", scenes: [scene])).contains("\n\(written)\nid: a\n"))
    }

    @Test func aHeadingInTheBodySplitsTheScene() {
        let book = parse(file(scene: "One.\n## Interlude\nTwo."))
        #expect(book.book.scenes.map(\.title) == ["S", "Interlude"])
        #expect(book.book.scenes[1].body.map(\.text) == ["Two."])
        #expect(
            book.book.scenes[1].errors == [
                RepairNotice.missingSceneID(given: .lettered(0)).entry,
                RepairNotice.missingModified(setTo: openedAt).entry,
            ])
    }

    @Test func metadata() throws {
        let scene = try onlyScene(
            "## S\nID: a-b_C9\nmodified: 2026-01-01T08:00:00Z\nTags: #one, two\\, three ,, \\#four, \\ five\\ , #\nid: b\n"
                + "Mara: hello\n\nBody.")
        #expect(scene.id.rawValue == "a-b_C9")
        #expect(scene.modified == (try timestamp("2026-01-01T08:00:00+00:00")))
        #expect(scene.tags == ["one", "two, three", "#four", " five "])
        #expect(scene.errors == [ErrorEntry(.metadata, "id: b"), ErrorEntry(.metadata, "Mara: hello")])
        #expect(scene.body.map(\.text) == ["Body."])
        #expect(
            file(scene).contains(
                "\nmodified: 2026-01-01T08:00:00+00:00\ntags: one, two\\, three, \\#four, \\ five\\ \n"))
    }

    @Test func badMetadataValuesGetDefaults() throws {
        let book = parse("## S\nid: has space\nmodified: 2026-10-31 20:40\n").book
        let scene = book.scenes[0]
        #expect(scene.id == .lettered(0) && scene.modified == openedAt)
        #expect(
            scene.errors == [
                ErrorEntry(.metadata, "id: has space"), ErrorEntry(.metadata, "modified: 2026-10-31 20:40"),
                RepairNotice.missingSceneID(given: .lettered(0)).entry,
                RepairNotice.missingModified(setTo: openedAt).entry,
            ])
    }

    @Test(arguments: [String(repeating: "x", count: 64), "01JC4K", "a_b-C"])
    func validIDs(id: String) throws {
        #expect(try onlyScene("## S\nid: \(id)\nmodified: 2026-01-01T00:00:00Z\n").id.rawValue == id)
    }

    @Test(arguments: [String(repeating: "x", count: 65), "a.b", "caf\u{E9}", "a+b"])
    func invalidIDs(id: String) throws {
        #expect(try onlyScene("## S\nid: \(id)\nmodified: 2026-01-01T00:00:00Z\n").id == .lettered(0))
    }

    @Test func aBlankLineUnderTheHeadingMakesTheMetadataBodyText() throws {
        let scene = try onlyScene("## S\n\nid: a\nmodified: 2026-01-01T00:00:00Z\n")
        #expect(scene.body.map(\.text) == ["id: a modified: 2026-01-01T00:00:00Z"])
        #expect(scene.errors.count == 2)
    }

    @Test func aDuplicateIDIsReplacedInFileOrderAcrossTheBoneyard() {
        let book = parse(
            "## A\nid: x\nmodified: 2026-01-01T00:00:00Z\n# Boneyard\n## B\nid: x\nmodified: 2026-01-01T00:00:00Z\n"
        ).book
        #expect(book.scenes[0].id.rawValue == "x")
        #expect(book.boneyard[0].id == .lettered(0))
        #expect(
            book.boneyard[0].errors == [
                RepairNotice.duplicateSceneID(SceneID(rawValue: "x"), given: .lettered(0)).entry
            ])
    }

    @Test func freshIDsNeverCollideWithIDsInTheFile() {
        struct Stuck: SceneIDSource {
            mutating func sceneID() -> SceneID { SceneID(rawValue: "taken") }
        }
        var ids = Stuck()
        let text =
            "## A\nmodified: 2026-01-01T00:00:00Z\n## B\nid: taken\nmodified: 2026-01-01T00:00:00Z\n## C\nmodified: 2026-01-01T00:00:00Z\n"
        let book = BookFormat.parse(Data(text.utf8), opened: openedAt, ids: &ids).book
        #expect(book.scenes.map(\.id.rawValue) == ["scene-1", "taken", "scene-2"])
    }

    @Test func subsectionsInAnyOrderRepeatedAndEmpty() throws {
        let text = file(
            scene:
                "Body.\n\n### Unparsed\n- [line] one\n\n### Notes\nFirst note.\n\n### Comments\n\n### Marks\n"
                + "### Notes\nSecond note.\n\n### Unparsed\n- [notice] two")
        let scene = try onlyScene(text)
        #expect(scene.notes.map(\.text) == ["First note.", "Second note."])
        #expect(scene.errors == [ErrorEntry(.line, "one"), ErrorEntry(.notice, "two")])
        #expect(
            file(scene).hasSuffix(
                "Body.\n\n### Notes\nFirst note.\n\nSecond note.\n\n### Unparsed\n- [line] one\n- [notice] two\n"
            ))
    }

    @Test func proseUnderAnEntrySectionIsAnError() throws {
        let scene = try onlyScene(file(scene: "### Marks\nloose words\n\n### Unparsed\nmore words"))
        #expect(scene.errors == [ErrorEntry(.marks, "loose words"), ErrorEntry(.line, "more words")])
    }
}

@Suite struct ParagraphGrammarTests {
    private func body(_ text: String) throws -> [Paragraph] {
        let scene = try onlyScene(file(scene: text))
        #expect(scene.errors.isEmpty, "\(scene.errors)")
        return scene.body
    }

    // MARK: §3.1, §3.2

    @Test func wrappedLinesAreJoinedWithOneSpace() throws {
        #expect(try body("One\n   two  \nthree\\\nfour").map(\.text) == ["One two three  four"])
    }

    @Test func emptyParagraphs() throws {
        #expect(
            try body("<br>\n\n<BR />\n\n<br/>\n\n<br> and more\n\n<br>\n<br>").map(\.text) == [
                "", "", "", "<br> and more", "<br> <br>",
            ])
        #expect(try body("<br>")[0].runs.isEmpty)
        #expect(
            file(plainScene(body: [[], [Run("<br>")], [Run("<BR/>")]])).hasSuffix(
                "\n<br>\n\n\\<br>\n\n\\<BR/>\n"))
    }

    // MARK: §3.3

    @Test(arguments: [
        (
            ##"\! \" \# \$ \% \& \' \( \) \* \+ \, \- \. \/ \: \; \< \= \> \? \@ \[ \\ \] \^ \_ \` \{ \| \} \~"##,
            #"! " # $ % & ' ( ) * + , - . / : ; < = > ? @ [ \ ] ^ _ ` { | } ~"#
        ),
        (#"C:\logs \é \1"#, #"C:\logs \é \1"#),
        (#"a\ \ b"#, "a  b"),
    ])
    func escapes(line: String, text: String) throws {
        #expect(try body(line).map(\.text) == [text])
    }

    // MARK: §3.4

    @Test(
        arguments: [
            ("**b**", [Run("b", styles: [.bold])]),
            ("*i*", [Run("i", styles: [.italic])]),
            ("~~s~~", [Run("s", styles: [.strike])]),
            ("***~~x~~***", [Run("x", styles: [.bold, .italic, .strike])]),
            ("*~~**x**~~*", [Run("x", styles: [.bold, .italic, .strike])]),
            ("a****b", [Run("ab")]),
            ("* * *", [Run("* * *")]),
            ("***", [Run("***")]),
            ("a * b", [Run("a * b")]),
            ("He said **wow.", [Run("He said **wow.")]),
            ("2*3*4", [Run("2"), Run("3", styles: [.italic]), Run("4")]),
            ("a ~ b ~c~", [Run("a ~ b ~c~")]),
            ("x~~~y~~~z", [Run("x"), Run("~y", styles: [.strike]), Run("~z")]),
            ("***x**", [Run("*x", styles: [.bold])]),
            ("\\*not\\*", [Run("*not*")]),
            ("**a\nb**", [Run("a b", styles: [.bold])]),
        ] as [(String, [Run])])
    func styles(line: String, runs: [Run]) throws {
        #expect(try body(line).first?.runs == runs)
    }

    @Test func stylesDontCarryAcrossParagraphs() throws {
        #expect(try body("**open\n\nclosed**").map(\.runs) == [[Run("**open")], [Run("closed**")]])
    }

    // MARK: §3.5, the table verbatim

    @Test(
        arguments: [
            ([Run("already", styles: [.bold])], "**already**"),
            ([Run("never", styles: [.bold, .italic, .strike])], "***~~never~~***"),
            (
                [
                    Run("when "), Run("the house… and ", styles: [.bold]),
                    Run("leaving", styles: [.bold, .italic]),
                    Run(" still… game.", styles: [.italic]),
                ], "when **the house… and *leaving** still… game.*"
            ),
            ([Run("Wait "), Run(" for", styles: [.bold]), Run(" it.")], #"Wait **\ for** it."#),
            ([Run("He said. ")], #"He said.\ "#),
            ([Run("#7 was on the gate")], ##"\#7 was on the gate"##),
            ([Run("5*3 and file_2 at C:\\")], #"5\*3 and file\_2 at C:\\"#),
            ([Run("* * *")], #"\* \* \*"#),
        ] as [([Run], String)])
    func writing(runs: [Run], written: String) {
        #expect(Inline.write(Paragraph(runs)) == written)
    }

    @Test(arguments: ["- item", "-", "---", "--- x", "#", "<br>", "<Br />", "-x", "--"])
    func lineStartsThatLookLikeStructure(text: String) throws {
        let written = Inline.write([Run(text)])
        let escaped = ["- item", "-", "---", "--- x", "#", "<br>", "<Br />"].contains(text)
        #expect(written.hasPrefix("\\") == escaped, "\(written)")
        #expect(try body(written).map(\.text) == [text])
    }

    @Test func aDelimiterNextToASpaceIsNeverFreeStanding() throws {
        let runs = [Run("a "), Run(" ", styles: [.bold]), Run(" b", styles: [.italic]), Run(" ")]
        let written = Inline.write(Paragraph(runs))
        #expect(written == #"a **\ ***\ b*\ "#)
        #expect(try body(written) == [Paragraph(runs)])
    }

    // MARK: §3.6

    @Test func plainTextOffsets() throws {
        let scene = try onlyScene(
            file(
                scene: "He found the **letter**.\n\nMara *watched*.\n\n### Comments\n"
                    + "- a | red | 2026-01-01T00:00:00Z | c13-19 | \"letter\" |\n- b | red | 2026-01-01T00:00:00Z | c21-25 | \"Mara\" |"
            ))
        #expect(scene.errors.isEmpty)
        #expect(plainText(scene.body) == "He found the letter.\nMara watched.")
    }
}

@Suite struct EntryGrammarTests {
    private static let created = "2026-10-31T20:40:00-07:00"

    /// A scene with the body `He found the letter.` / `Mara watched.` and notes `Tide tables.`.
    private func scene(_ section: String) throws -> BookScene {
        try onlyScene(
            file(scene: "He found the letter.\n\nMara watched.\n\n### Notes\nTide tables.\n\n" + section))
    }

    // MARK: §4.4, §4.5

    @Test func commentEntries() throws {
        let scene = try scene(
            "### Comments\n- c7 | PURPLE | \(Self.created) | C13-19 | \"letter\" | Too early | maybe?\n"
                + "-   c8|grey|2026-01-01T00:00:00Z|c0-2 ,notes c0-4|\"He\" , \"Tide\"|  \\ spaced\\n two\\ \n"
                + "- c9 | black | \(Self.created) | Detached |\n"
                + "- c10 | red | \(Self.created) | c16-24 | \"ter.\\nMar\" | wrapped\nonto two lines")
        #expect(scene.errors.isEmpty, "\(scene.errors)")
        #expect(scene.comments.map(\.id.rawValue) == ["c7", "c8", "c9", "c10"])
        #expect(scene.comments.map(\.color) == [.purple, .gray, .black, .red])
        #expect(
            scene.comments.map(\.text) == [
                "Too early | maybe?", " spaced\n two ", "", "wrapped onto two lines",
            ])
        #expect(scene.isDetached(CommentID(rawValue: "c9")))
        let c10 = CommentID(rawValue: "c10")
        #expect(
            scene.body.map { $0.runs.filter { $0.comments.contains(c10) }.map(\.text).joined() } == [
                "ter.", "Mar",
            ])
        #expect(scene.notes[0].runs.first == Run("Tide", comments: [CommentID(rawValue: "c8")]))
        #expect(
            file(scene).contains(
                "### Comments\n- c7 | purple | 2026-10-31T20:40:00-07:00 | c13-19 | \"letter\" | Too early | maybe?\n"
                    + "- c8 | gray | 2026-01-01T00:00:00+00:00 | c0-2, notes c0-4 | \"He\", \"Tide\" | \\ spaced\\n two\\ \n"
                    + "- c9 | black | 2026-10-31T20:40:00-07:00 | detached |\n"
                    + "- c10 | red | 2026-10-31T20:40:00-07:00 | c16-24 | \"ter.\\nMar\" | wrapped onto two lines\n"
            ))
    }

    @Test func rangesAreWrittenMergedAndSorted() throws {
        let scene = try scene(
            "### Comments\n- c1 | red | \(Self.created) | c13-21, c0003-4, c3-5, c9-13 | \"letter.\\n\", \"f\", \"fo\", \"the \" |"
        )
        #expect(scene.errors.isEmpty, "\(scene.errors)")
        #expect(file(scene).contains("| c3-5, c9-20 | \"fo\", \"the letter.\" |"))
    }

    @Test func aCommentAcrossParagraphsIsOneRange() throws {
        let scene = try scene("### Comments\n- c1 | red | \(Self.created) | c13-25 | \"letter.\\nMara\" |")
        #expect(scene.errors.isEmpty)
        #expect(file(scene).contains("| c13-25 | \"letter.\\nMara\" |"))
    }

    // MARK: §4.6, §4.7

    @Test func markEntries() throws {
        let scene = try scene(
            "### Marks\n- highlight blue | c26-33 | \"watched\"\n- COLOR Red | c0-8 | \"He found\"\n"
                + "- color purple | c3-8 | \"found\"\n- color black | c0-1 | \"H\"\n- highlight grey | notes c0-4 | \"Tide\""
        )
        #expect(scene.errors.isEmpty, "\(scene.errors)")
        #expect(
            scene.body[0].runs == [
                Run("H"), Run("e ", color: .red), Run("found", color: .purple), Run(" the letter."),
            ])
        #expect(
            file(scene).contains(
                "### Marks\n- color red | c1-3 | \"e \"\n- color purple | c3-8 | \"found\"\n"
                    + "- highlight blue | c26-33 | \"watched\"\n- highlight gray | notes c0-4 | \"Tide\"\n"))
    }

    @Test func aMarkAcrossParagraphsIsOneEntry() throws {
        let scene = try scene("### Marks\n- color red | c13-20, c21-25 | \"letter.\", \"Mara\"")
        #expect(scene.errors.isEmpty)
        #expect(file(scene).contains("- color red | c13-25 | \"letter.\\nMara\"\n"))
    }

    // MARK: §4.8, E1–E10

    @Test(arguments: [
        ("Remember to fix this", EntryProblem.strayLine),
        ("- c1 | purple | letter", .fields),
        ("- c1 | purple | \(created) | c13-19", .fields),
        ("- | purple | \(created) | c13-19 | \"letter\" |", .fields),
        ("- c1 | purple | \(created) | c13-19 | \"letter\"", .fields),
        ("- c 1 | purple | \(created) | c13-19 | \"letter\" |", .commentID),
        ("- dup | purple | \(created) | c13-19 | \"letter\" |", .commentID),
        ("- c1 | mauve | \(created) | c13-19 | \"letter\" |", .paletteName),
        ("- c1 | purple | 2026-10-31 20:40 | c13-19 | \"letter\" |", .timestamp),
        ("- c1 | purple | \(created) | c13to19 | \"letter\" |", .rangeSyntax),
        ("- c1 | purple | \(created) | 13-19 | \"letter\" |", .rangeSyntax),
        ("- c1 | purple | \(created) | c13-19, | \"letter\" |", .rangeSyntax),
        ("- c1 | purple | \(created) | notesc0-4 | \"Tide\" |", .rangeSyntax),
        ("- c1 | purple | \(created) | c19-13 | \"letter\" |", .rangeBounds),
        ("- c1 | purple | \(created) | c400-410 | \"letter\" |", .rangeBounds),
        ("- c1 | purple | \(created) | c20-21 | \"\\n\" |", .rangeBounds),
        ("- c1 | purple | \(created) | notes c0-40 | \"Tide\" |", .rangeBounds),
        ("- c1 | purple | \(created) | c13-19 | \"letter |", .quoteSyntax),
        ("- c1 | purple | \(created) | c13-19, c0-2 | \"letter\" |", .quoteSyntax),
        ("- c1 | purple | \(created) | c13-19 | letter |", .quoteSyntax),
        ("- c1 | purple | \(created) | c13-19 | \"lettre\" |", .quoteMismatch),
        ("- c1 | purple | \(created) | c13-19 | \"the **letter**\" |", .quoteMismatch),
    ])
    func commentErrors(line: String, problem: EntryProblem) throws {
        let scene = try scene("### Comments\n- dup | red | \(Self.created) | c0-2 | \"He\" |\n\n\(line)")
        #expect(scene.errors == [ErrorEntry(.comments, line)])
        #expect(scene.comments.map(\.id.rawValue) == ["dup"], "the error has no effect")
        if problem != .strayLine {
            let context = EntryContext(
                body: SceneText(scene.body.map(styled)), notes: SceneText(scene.notes.map(styled)),
                commentIDs: [CommentID(rawValue: "dup")])
            #expect(Entries.comment(Array(line.utf8), in: context) == .failure(problem))
        }
    }

    @Test(arguments: [
        ("stray", EntryProblem.strayLine),
        ("- color red", .fields),
        ("- color | c0-2 | \"He\"", .fields),
        ("- underline red | c0-2 | \"He\"", .paletteName),
        ("- highlight black | c0-2 | \"He\"", .paletteName),
        ("- color mauve | c0-2 | \"He\"", .paletteName),
        ("- color red | detached | \"He\"", .rangeSyntax),
        ("- color red | c0-99 | \"He\"", .rangeBounds),
        ("- color red | c0-2 | \"He", .quoteSyntax),
        ("- color red | c0-2 | \"Hx\"", .quoteMismatch),
        ("- color red | c0-3 | \"He \" | extra", .leftover),
        ("- color red | c0-2 | \"He\" junk", .leftover),
    ])
    func markErrors(line: String, problem: EntryProblem) throws {
        let scene = try scene("### Marks\n\(line)")
        #expect(scene.errors == [ErrorEntry(.marks, line)])
        #expect(scene.body.flatMap(\.runs).allSatisfy { $0.color == nil && $0.highlight == nil })
        if problem != .strayLine {
            let context = EntryContext(
                body: SceneText(scene.body.map(styled)), notes: SceneText(scene.notes.map(styled)),
                commentIDs: [])
            #expect(Entries.mark(Array(line.utf8), in: context) == .failure(problem))
        }
    }

    @Test func aStrayLineIsE1ButALineUnderAnEntryContinuesIt() throws {
        let scene = try scene(
            "### Comments\n- c1 | red | \(Self.created) | c0-2 | \"He\" | one\ntwo\n\nRemember to fix this")
        #expect(scene.comments.map(\.text) == ["one two"])
        #expect(scene.errors == [ErrorEntry(.comments, "Remember to fix this")])
    }

    @Test func aContinuationThatBreaksTheEntryMakesItAnError() throws {
        let scene = try scene("### Marks\n- color red | c0-2 | \"He\"\nextra")
        #expect(scene.errors == [ErrorEntry(.marks, "- color red | c0-2 | \"He\" extra")])
    }

    // MARK: §5.1 Unparsed

    @Test(arguments: [
        ("- [front matter] author: S. Basu", ErrorEntry(.frontMatter, "author: S. Basu")),
        ("- [METADATA]   mood: grim", ErrorEntry(.metadata, "mood: grim")),
        ("- [notice]", ErrorEntry(.notice, "")),
        ("-", ErrorEntry(.line, "-")),
        ("- [foo] x", ErrorEntry(.line, "- [foo] x")),
        ("- [line]x", ErrorEntry(.line, "- [line]x")),
        ("- [comments] - c1 | x", ErrorEntry(.comments, "- c1 | x")),
    ])
    func unparsedEntries(line: String, entry: ErrorEntry) throws {
        let scene = try scene("### Unparsed\n\(line)")
        #expect(scene.errors == [entry])
        #expect(file(scene).hasSuffix("### Unparsed\n- \(entry)\n"))
    }

    @Test func unparsedPayloadsAreNeverReparsed() throws {
        let scene = try scene("### Unparsed\n- [comments] - c1 | red | \(Self.created) | c0-2 | \"He\" |")
        #expect(scene.comments.isEmpty)
        #expect(scene.errors.count == 1)
        let again = parse(file(scene)).book.scenes[0]
        #expect(again == scene)
    }

    @Test func entriesAreInFileOrderThenNotices() throws {
        let book = parse(
            "## S\nmood: grim\n\nα\n\n### Comments\n- bad\n\n### Unparsed\n- [line] kept\n\n### Marks\n- color x | c0-1 | \"a\""
        )
        let scene = book.book.scenes[0]
        #expect(
            scene.errors == [
                ErrorEntry(.metadata, "mood: grim"), ErrorEntry(.comments, "- bad"),
                ErrorEntry(.line, "kept"),
                ErrorEntry(.marks, "- color x | c0-1 | \"a\""),
                RepairNotice.missingSceneID(given: .lettered(0)).entry,
                RepairNotice.missingModified(setTo: openedAt).entry,
                RepairNotice.replacedCharacters(["α"]).entry,
            ])
    }
}
