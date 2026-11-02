import Foundation
import Testing

@testable import SceneItCore

/// The examples of docs/format/book-format.md §9, and the owner's demo book.
@Suite struct SpecExampleTests {
    @Test func theDemoBookRoundTripsByteForByte() throws {
        let bytes = try Fixture.data("demo-book")
        let parsed = parse(bytes)
        #expect(Array(parsed.book.errorEntries.joined()) == [])
        #expect(parsed.declaredFormat == .current)
        #expect(
            parsed.book.scenes.count > 20 && parsed.book.boneyard.count == 2, "precondition: the whole demo")
        #expect(BookFormat.serialize(parsed.book) == bytes)
        #expect(try BookFormat.verifiedSerialization(of: parsed.book) == bytes)
    }

    @Test func theDemoBookCommentsAndMarksLand() throws {
        let book = parse(try Fixture.data("demo-book")).book
        let ferry = book.scenes[0]
        #expect(ferry.comments.map(\.id.rawValue) == ["c2", "c1"])
        let letter = ferry.body.flatMap(\.runs).filter { $0.comments == [CommentID(rawValue: "c1")] }
        #expect(letter.map(\.text) == ["letter"])
        #expect(
            ferry.notes.flatMap(\.runs).filter { $0.color == .red }.map(\.text) == ["Decide before scene 3."])
    }

    // MARK: §9.1

    @Test func theCompleteExampleIsCanonical() throws {
        let bytes = try Fixture.data("complete-example")
        let parsed = parse(bytes)
        #expect(BookFormat.serialize(parsed.book) == bytes)
        #expect(try BookFormat.verifiedSerialization(of: parsed.book) == bytes)
        #expect(parsed.book.errorEntries.joined().count == 3, "the three error entries it started with")
    }

    @Test func theCompleteExampleParsesAsTheSpecSays() throws {
        let book = parse(try Fixture.data("complete-example")).book
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
        let bytes = try Fixture.text("complete-example")
        let stripped = try bytes.replacingFirst("to no one.\\ \n", with: "to no one.\\\n")
        #expect(parse(stripped).book == parse(bytes).book)
    }

    // MARK: §9.2

    /// The example as the spec describes it: `\r\n` endings, no final newline, and each
    /// `⟨93⟩`/`⟨94⟩` the single byte it stands for.
    static func damagedBytes() throws -> Data {
        var text = try Fixture.text("damaged-example")
        text.removeLast()
        var bytes: [UInt8] = []
        var rest = Substring(text.replacingOccurrences(of: "\n", with: "\r\n"))
        for (marker, byte) in [("\u{27E8}93\u{27E9}", UInt8(0x93)), ("\u{27E8}94\u{27E9}", 0x94)] {
            let range = try #require(rest.range(of: marker))
            bytes += Array(rest[..<range.lowerBound].utf8) + [byte]
            rest = rest[range.upperBound...]
        }
        return Data(bytes + Array(rest.utf8))
    }

    @Test func theDamagedExampleBytesAreAsDescribed() throws {
        let bytes = try Self.damagedBytes()
        #expect(String(validating: bytes, as: UTF8.self) == nil, "precondition: invalid UTF-8")
        #expect(bytes.filter { $0 == 0x93 || $0 == 0x94 }.count == 2)
        #expect(bytes.last == UInt8(ascii: "d"), "cut off in the middle of the last line")
        #expect(bytes.filter { $0 == 0x0D }.count == bytes.filter { $0 == 0x0A }.count)
    }

    @Test func theDamagedExampleParsesToItsTwelveEntries() throws {
        let book = parse(try Self.damagedBytes()).book
        let (a, b, c) = (SceneID.lettered(0), SceneID.lettered(1), SceneID.lettered(2))
        #expect(book.title == "My Novel")
        #expect(
            book.errors == [
                ErrorEntry(.frontMatter, "colour: blue"),
                ErrorEntry(.line, "Remember to back this up!"),
                RepairNotice.invalidUTF8(byteCount: 2).entry,
            ])
        try #require(book.scenes.count == 4 && book.boneyard.isEmpty)
        let (ferry, arrival, interlude, letter) = (
            book.scenes[0], book.scenes[1], book.scenes[2], book.scenes[3]
        )

        #expect(ferry.id.rawValue == "01JCM9S346Q3D25VT4F5V37E3S")
        #expect(ferry.modified == (try timestamp("2026-11-02T09:00:00-08:00")))
        #expect(
            ferry.body.map(\.text) == [
                "The ferry left at dawn, and Mara watched the harbor lights go out one by one behind her.",
                "\"Wait,\" she said. [?]",
            ])
        #expect(ferry.comments.map(\.id.rawValue) == ["c2"])
        #expect(
            ferry.errors == [
                ErrorEntry(
                    .comments,
                    "- c1 | mauve | 2026-10-31T20:40:00-07:00 | c45-58 | \"harbor lights\" | Too pretty?"),
                ErrorEntry(
                    .comments,
                    "- c3 | blue | 2026-10-31T20:41:00-07:00 | c4-9 | \"ferry left\" | Wrong range."),
                RepairNotice.replacedCharacters(["\u{1F30A}"]).entry,
            ])
        #expect(
            ferry.errors[2].payload == "Characters Scene It can't store were replaced with [?]: U+1F30A.")

        #expect(arrival.id == a)
        #expect(arrival.modified == (try timestamp("2026-11-02T03:18:00-08:00")))
        #expect(arrival.body.map(\.text) == ["Nobody met her at the landing."])
        #expect(arrival.errors == [RepairNotice.missingSceneID(given: a).entry])
        #expect(arrival.errors[0].payload == "This scene had no id, so it was given \(a).")

        #expect(interlude.title == "Interlude" && interlude.id == b && interlude.modified == openedAt)
        #expect(
            interlude.body.map(\.text) == [
                "The gulls were louder than she remembered.", "Gulls: check species.",
            ])
        #expect(
            interlude.errors == [
                ErrorEntry(.line, "### Note"),
                RepairNotice.missingSceneID(given: b).entry,
                RepairNotice.missingModified(setTo: openedAt).entry,
            ])
        #expect(
            interlude.errors[2].payload == "This scene had no modified date, so it was set to \(openedAt).")

        #expect(letter.id == c)
        #expect(letter.body.map(\.text) == ["He read it twice before he understood \"mother\""])
        #expect(letter.comments.isEmpty)
        #expect(
            letter.errors == [
                ErrorEntry(.comments, "- c1 | purple | 2026-11-01T15:30:00-08:00 | c3-7 | \"read"),
                RepairNotice.duplicateSceneID(SceneID(rawValue: "01JCM9S346Q3D25VT4F5V37E3S"), given: c)
                    .entry,
            ])
        #expect(
            letter.errors[1].payload
                == "This scene's id 01JCM9S346Q3D25VT4F5V37E3S was already used by an earlier scene, so it was given \(c)."
        )

        #expect(book.errorEntries.joined().count == 12, "the writer sees twelve rows")
    }

    @Test func theDamagedExampleEntryReasonsAreTheSpecs() throws {
        let book = parse(try Self.damagedBytes()).book
        let ferry = book.scenes[0]
        let context = EntryContext(
            body: SceneText(ferry.body.map(styled)), notes: SceneText([]),
            commentIDs: [CommentID(rawValue: "c2")])
        #expect(Entries.comment(Array(ferry.errors[0].payload.utf8), in: context) == .failure(.paletteName))
        #expect(Entries.comment(Array(ferry.errors[1].payload.utf8), in: context) == .failure(.quoteMismatch))
        let letter = book.scenes[3]
        let letterContext = EntryContext(
            body: SceneText(letter.body.map(styled)), notes: SceneText([]), commentIDs: [])
        #expect(
            Entries.comment(Array(letter.errors[0].payload.utf8), in: letterContext) == .failure(.quoteSyntax)
        )
    }

    @Test func theDamagedExampleSavesCleanAndKeepsItsEntries() throws {
        let book = parse(try Self.damagedBytes()).book
        let saved = try BookFormat.verifiedSerialization(of: book)
        let text = String(decoding: saved, as: UTF8.self)
        #expect(String(validating: saved, as: UTF8.self) != nil)
        #expect(!text.contains("\r"))
        #expect(
            text.contains(
                "The ferry left at dawn, and Mara watched the harbor lights go out one by one behind her.\n"))
        #expect(text.contains("\"Wait,\" she said. [?]\n"))
        #expect(
            text.hasPrefix(
                "---\ntitle: My Novel\nformat: 2\n---\n\n### Unparsed\n- [front matter] colour: blue\n"))
        #expect(parse(saved).book == book)
    }
}

/// The paragraph's runs with only their styles, merged where the rest differed.
func stylesOnly(_ paragraph: Paragraph) -> [Run] {
    BookGenerator.merged(paragraph.runs.map { Run($0.text, styles: $0.styles) })
}

func plainText(_ paragraphs: [Paragraph]) -> String {
    paragraphs.map(\.text).joined(separator: "\n")
}

/// A model paragraph as the parser holds it, for checking entries against it.
func styled(_ paragraph: Paragraph) -> StyledText {
    let text = Array(paragraph.text.unicodeScalars.map { UInt8($0.value) })
    return StyledText(text: text, styles: Array(repeating: [], count: text.count))
}
