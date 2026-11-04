import Foundation
import Testing

@testable import SceneItCore

/// Book format §1–§5, rule by rule. Every table row that has an input and a result is a corpus
/// case (Tests/Corpus/book), which pins its bytes and entries; these say what the parse means.
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

    @Test func unknownHeadingsLeaveTheSectionAlone() throws {
        let scene = try onlyScene(case: "s1.4-unknown-headings-are-lines")
        #expect(scene.body.map(\.text) == ["Before.", "After.", "Last."])
    }

    @Test func aKnownSubsectionHeadingInTheBodyIsASubsection() throws {
        let scene = try onlyScene(case: "s1.4-known-subsection-heading-in-body")
        #expect(scene.body.map(\.text) == ["Body."])
        #expect(scene.notes.map(\.text) == ["Now notes."])
    }

    // MARK: §1.5 Front matter

    @Test func frontMatterLines() throws {
        let parsed = try parse(case: "s1.5-front-matter-lines")
        #expect(parsed.book.title == "A | b, c\n")
        #expect(parsed.declaredFormat == FormatVersion(2))
    }

    @Test func aBadFormatIsMissing() throws {
        #expect(try parse(case: "s1.5-bad-format").declaredFormat == nil)
    }

    @Test func aNewerFormatIsReadAsNewer() throws {
        let parsed = try parse(case: "s1.5-newer-format")
        #expect(parsed.declaredFormat == FormatVersion(3))
        #expect(parsed.isNewerThanSupported)
        let older = try parse(case: "s1.5-older-format")
        #expect(older.declaredFormat == FormatVersion(1))
        #expect(!older.isNewerThanSupported)
    }

    // MARK: §2 Scenes

    @Test(arguments: [
        ("s2.1-title-formatting-dropped", "The ferry"),
        ("s2.1-title-empty", ""),
        ("s2.1-title-empty-with-space", ""),
        ("s2.1-title-spaced", "spaced"),
        ("s2.1-title-escaped-edge-spaces", " edges "),
        ("s2.1-title-literal-markup-characters", "a * b and_c ~ d"),
        ("s2.1-title-unbalanced-bold", "He said **wow."),
        ("s2.1-title-backslash-before-letter", #"C:\logs"#),
        ("s2.1-title-hash-and-br", "#7 <br>"),
    ])
    func titles(name: String, title: String) throws {
        #expect(try onlyScene(case: name).title.text == title)
    }

    @Test func metadata() throws {
        let scene = try onlyScene(case: "s2.2-metadata")
        #expect(scene.id.rawValue == "a-b_C9")
        #expect(scene.modified == (try timestamp("2026-01-01T08:00:00+00:00")))
        #expect(scene.tags == ["one", "two, three", "#four", " five "])
        #expect(scene.body.map(\.text) == ["Body."])
    }

    @Test func freshIDsNeverCollideWithIDsInTheFile() throws {
        struct Stuck: SceneIDSource {
            mutating func sceneID() -> SceneID { SceneID(rawValue: "taken") }
        }
        var ids = Stuck()
        let text = try Corpus.book("s2.2-fresh-ids-avoid-ids-in-the-file")
        let book = BookFormat.parse(text, opened: openedAt, ids: &ids).book
        #expect(book.scenes.map(\.id.rawValue) == ["scene-1", "taken", "scene-2"])
    }
}

@Suite struct ParagraphGrammarTests {
    private func body(_ name: String) throws -> [Paragraph] {
        try onlyScene(case: name).body
    }

    /// The body of a file whose scene's only text is `line`, which must read without errors.
    private func body(reading line: String) throws -> [Paragraph] {
        let scene = try onlyScene(file(scene: line))
        #expect(scene.errors.isEmpty, "\(scene.errors)")
        return scene.body
    }

    // MARK: §3.1, §3.2

    @Test func wrappedLinesAreJoinedWithOneSpace() throws {
        #expect(try body("s3.1-wrapped-lines").map(\.text) == ["One two three  four"])
    }

    @Test func emptyParagraphs() throws {
        #expect(
            try body("s3.2-empty-paragraphs").map(\.text) == ["", "", "", "<br> and more", "<br> <br>"])
        #expect(try body("s3.2-br-alone")[0].runs.isEmpty)
        #expect(
            file(plainScene(body: [[], [Run("<br>")], [Run("<BR/>")]])).hasSuffix(
                "\n<br>\n\n\\<br>\n\n\\<BR/>\n"))
    }

    // MARK: §3.3

    @Test(arguments: [
        (
            "s3.3-escapes-every-punctuation-character",
            #"! " # $ % & ' ( ) * + , - . / : ; < = > ? @ [ \ ] ^ _ ` { | } ~"#
        ),
        ("s3.3-backslash-before-other-characters", #"C:\logs \e \1"#),
        ("s3.3-escaped-spaces", "a  b"),
    ])
    func escapes(name: String, text: String) throws {
        #expect(try body(name).map(\.text) == [text])
    }

    // MARK: §3.4

    @Test(
        arguments: [
            ("s3.4-bold", [Run("b", styles: [.bold])]),
            ("s3.4-italic", [Run("i", styles: [.italic])]),
            ("s3.4-strike", [Run("s", styles: [.strike])]),
            ("s3.4-all-three", [Run("x", styles: [.bold, .italic, .strike])]),
            ("s3.4-all-three-in-another-order", [Run("x", styles: [.bold, .italic, .strike])]),
            ("s3.4-redundant-toggles", [Run("ab")]),
            ("s3.4-spaced-scene-break", [Run("* * *")]),
            ("s3.4-scene-break", [Run("***")]),
            ("s3.4-free-standing-star", [Run("a * b")]),
            ("s3.4-unbalanced-bold", [Run("He said **wow.")]),
            ("s3.4-stars-between-digits", [Run("2"), Run("3", styles: [.italic]), Run("4")]),
            ("s3.4-lone-tildes", [Run("a ~ b ~c~")]),
            ("s3.4-triple-tildes", [Run("x"), Run("~y", styles: [.strike]), Run("~z")]),
            ("s3.4-unbalanced-italic", [Run("*x", styles: [.bold])]),
            ("s3.4-escaped-stars", [Run("*not*")]),
            ("s3.4-bold-across-a-wrapped-line", [Run("a b", styles: [.bold])]),
        ] as [(String, [Run])])
    func styles(name: String, runs: [Run]) throws {
        #expect(try body(name).first?.runs == runs)
    }

    @Test func stylesDontCarryAcrossParagraphs() throws {
        #expect(
            try body("s3.4-styles-dont-carry-across-paragraphs").map(\.runs) == [
                [Run("**open")], [Run("closed**")],
            ])
    }

    // MARK: §3.5, the table verbatim

    @Test(
        arguments: [
            ([Run("already", styles: [.bold])], "**already**"),
            ([Run("never", styles: [.bold, .italic, .strike])], "***~~never~~***"),
            (
                [
                    Run("when "), Run("the house was asleep and ", styles: [.bold]),
                    Run("leaving", styles: [.bold, .italic]),
                    Run(" still seemed like a game.", styles: [.italic]),
                ], "when **the house was asleep and *leaving** still seemed like a game.*"
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
        #expect(try body(reading: written).map(\.text) == [text])
    }

    @Test func aDelimiterNextToASpaceIsNeverFreeStanding() throws {
        let runs = [Run("a "), Run(" ", styles: [.bold]), Run(" b", styles: [.italic]), Run(" ")]
        let written = Inline.write(Paragraph(runs))
        #expect(written == #"a **\ ***\ b*\ "#)
        #expect(try body(reading: written) == [Paragraph(runs)])
    }

    // MARK: §3.6

    @Test func plainTextOffsets() throws {
        let scene = try onlyScene(case: "s3.6-plain-text-offsets")
        #expect(plainText(scene.body) == "He found the letter.\nMara watched.")
        #expect(scene.comments.count == 2)
    }
}

@Suite struct EntryGrammarTests {
    // MARK: §4.3–§4.7

    @Test func commentEntries() throws {
        let scene = try onlyScene(case: "s4.4-comment-entries")
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
        let c8 = CommentID(rawValue: "c8")
        #expect(scene.body[0].runs.filter { $0.comments.contains(c8) }.map(\.text) == ["He", "found"])
    }

    /// §4.3: only `\"`, `\\` and `\n` are escapes in a quote; any other backslash is text.
    @Test func quotesKeepOtherBackslashes() throws {
        let scene = try onlyScene(case: "s4.3-quotes-keep-other-backslashes")
        #expect(scene.body.map(\.text) == ["a\\,b \\| \"q\""], "precondition")
        #expect(scene.comments.count == 2)
    }

    @Test func markEntries() throws {
        let scene = try onlyScene(case: "s4.6-mark-entries")
        #expect(
            scene.body[0].runs == [
                Run("H"), Run("e ", color: .red), Run("found", color: .purple), Run(" the letter."),
            ])
    }
}
