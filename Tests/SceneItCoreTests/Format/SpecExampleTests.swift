import Foundation
import Testing

@testable import SceneItCore

/// The examples of docs/format/book-format.md §9, and the owner's demo book, read as the spec
/// describes them. Their corpus cases pin the bytes and entries.
@Suite struct SpecExampleTests {
    @Test func theDemoBookIsItsOwnCanonicalForm() throws {
        let bytes = try Corpus.book("demo-book")
        #expect(bytes == (try Corpus.data(.book, "demo-book", .expected)))
        let parsed = parse(bytes)
        #expect(parsed.declaredFormat == .current)
        #expect(
            parsed.book.scenes.count > 20 && parsed.book.boneyard.count == 2, "precondition: the whole demo")
    }

    @Test func theDemoBookCommentsAndMarksLand() throws {
        let book = parse(try Corpus.book("demo-book")).book
        let ferry = book.scenes[0]
        #expect(ferry.comments.map(\.id.rawValue) == ["c2", "c1"])
        let letter = ferry.body.flatMap(\.runs).filter { $0.comments == [CommentID(rawValue: "c1")] }
        #expect(letter.map(\.text) == ["letter"])
        #expect(
            ferry.notes.flatMap(\.runs).filter { $0.color == .red }.map(\.text) == ["Decide before scene 3."])
    }

    // MARK: §9.1

    @Test func theCompleteExampleIsCanonical() throws {
        #expect(
            try Corpus.book("s9.1-complete-book") == (try Corpus.data(.book, "s9.1-complete-book", .expected))
        )
    }

    @Test func theCompleteExampleParsesAsTheSpecSays() throws {
        let book = parse(try Corpus.book("s9.1-complete-book")).book
        #expect(book.title == "My Novel")
        #expect(book.errors == [ErrorEntry(.frontMatter, "author: S. Basu")])
        try #require(book.scenes.count == 3 && book.boneyard.count == 1)
        let (ferry, arrival, letter) = (book.scenes[0], book.scenes[1], book.scenes[2])

        #expect(
            stylesOnly(ferry.body[1]) == [
                Run("She had packed in the dark, "),
                Run("by feel", styles: [.italic]),
                Run(", the way she used to as a girl when "),
                Run("the house was asleep and ", styles: [.bold]),
                Run("leaving", styles: [.bold, .italic]),
                Run(" still seemed like a game.", styles: [.italic]),
            ])
        let already = try #require(ferry.body[2].runs.first { $0.text == "already" })
        #expect(already.styles == [.bold, .italic, .strike])
        #expect(ferry.body[2].runs.last == Run(" ashore."))
        #expect(plainText(ferry.body).count == 405)
        #expect(ferry.comments.map(\.id.rawValue) == ["c2", "c1", "c4", "c5", "c7", "c6"])
        #expect(ferry.comments[2].text == "")
        #expect(ferry.comments[3].text == #"Too much | "noise" here?"#)
        #expect(ferry.isDetached(CommentID(rawValue: "c6")))
        #expect(!ferry.isDetached(CommentID(rawValue: "c7")))
        #expect(ferry.errors.isEmpty)

        let c4 = CommentID(rawValue: "c4")
        let c4Text = ferry.body.map { $0.runs.filter { $0.comments.contains(c4) }.map(\.text).joined() }
        #expect(
            c4Text == [
                "at dawn, and Mara watched the harbor lights go out one by one behind her.",
                "She had packed in the dark",
                "",
            ])
        let overlap = ferry.body[0].runs.filter { $0.comments == [CommentID(rawValue: "c2"), c4] }
        #expect(overlap.map(\.text) == ["at dawn"])
        #expect(
            ferry.body[0].runs.contains {
                $0.text == "harbor lights" && $0.color == .purple && $0.comments == [c4]
            })

        #expect(
            arrival.body.dropFirst(3).map(\.text) == [
                "#7 was painted on the gate, and under it someone had chalked *KEEP OUT*.",
                "",
                "- Hello? she called, to the gate, to the gulls, to no one. ",
                "A tin sign read ROOM_2 ~ C:\\ATTIC.",
            ])
        #expect(arrival.body[4].runs.isEmpty)
        #expect(plainText(arrival.body).count == 445)
        #expect(plainText(arrival.body).contains("*KEEP OUT*.\n\n- Hello?"))

        #expect(letter.tags == ["mother", "clue", "letters, unsent"])
        #expect(
            letter.errors == [
                ErrorEntry(
                    .comments, "- c9 | purpel | 2026-11-01T15:30:00-08:00 | c17-23 | \"before\" | Too slow?"),
                ErrorEntry(.metadata, "mood: grim"),
            ])
        let context = EntryContext(body: SceneText([]), notes: SceneText([]), commentIDs: [])
        #expect(Entries.comment(Array(letter.errors[0].payload.utf8), in: context) == .failure(.paletteName))

        #expect(book.boneyard[0].comments.map(\.id.rawValue) == ["c1"])
    }

    @Test func spellingTheEscapedSpaceWithoutItsSpaceReadsTheSame() throws {
        let complete = try Corpus.book("s9.1-complete-book")
        let stripped = try Corpus.book("s9.1-escaped-space-stripped")
        #expect(stripped.count == complete.count - 1, "precondition: only the space is gone")
        #expect(parse(stripped).book == parse(complete).book)
    }

    // MARK: §9.2

    /// The example as the spec describes it: `\r\n` endings, no final newline, and each
    /// `⟨93⟩`/`⟨94⟩` the single byte it stands for.
    static func damagedBytes() throws -> Data {
        try Corpus.book("s9.2-damaged-book")
    }

    @Test func theDamagedExampleBytesAreAsDescribed() throws {
        let bytes = try Self.damagedBytes()
        #expect(String(validating: bytes, as: UTF8.self) == nil, "precondition: invalid UTF-8")
        #expect(bytes.filter { $0 == 0x93 || $0 == 0x94 }.count == 2)
        #expect(bytes.last == UInt8(ascii: "d"), "cut off in the middle of the last line")
        #expect(bytes.filter { $0 == 0x0D }.count == bytes.filter { $0 == 0x0A }.count)
    }
}

/// The paragraph's runs with only their styles, merged where the rest differed.
func stylesOnly(_ paragraph: Paragraph) -> [Run] {
    BookGenerator.merged(paragraph.runs.map { Run($0.text, styles: $0.styles) })
}

func plainText(_ paragraphs: [Paragraph]) -> String {
    paragraphs.map(\.text).joined(separator: "\n")
}
