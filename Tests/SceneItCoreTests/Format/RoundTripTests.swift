import Foundation
import Testing

@testable import SceneItCore

/// Book format §7: the canonical form, and save verification.
@Suite struct RoundTripTests {
    // MARK: §7.2, as a property over generated books

    @Test(arguments: 0..<300)
    func generatedBooksRoundTrip(seed: UInt64) throws {
        var generator = BookGenerator(seed: seed ^ fuzzSalt)
        let book = generator.book()
        let bytes = BookFormat.serialize(book)
        let parsed = parse(bytes)
        #expect(parsed.book.errorEntries == book.errorEntries, "no new entries")
        #expect(BookFormat.serialize(parsed.book) == bytes, "serialize(parse(serialize(b))) == serialize(b)")
        #expect(parsed.book == book, "maximal runs read back as themselves")
        #expect(try BookFormat.verifiedSerialization(of: book) == bytes)
    }

    @Test func theGeneratorCoversTheFormat() {
        var books: [Book] = []
        for seed in UInt64(0)..<300 {
            var generator = BookGenerator(seed: seed ^ fuzzSalt)
            books.append(generator.book())
        }
        let scenes = books.flatMap { $0.scenes + $0.boneyard }
        let runs = scenes.flatMap { $0.body + $0.notes }.flatMap(\.runs)
        #expect(Set(runs.flatMap(\.styles)) == Set(TextStyle.allCases))
        #expect(runs.contains { $0.comments.count >= 2 }, "overlapping comments")
        #expect(scenes.contains { scene in scene.comments.contains { scene.isDetached($0.id) } })
        #expect(scenes.contains { $0.body.contains { $0.runs.isEmpty } }, "an empty paragraph")
        #expect(
            scenes.contains {
                !$0.notes.isEmpty && $0.notes.contains { $0.runs.contains { $0.color != nil } }
            })
        #expect(Set(scenes.flatMap(\.errors).map(\.tag)) == Set(ErrorTag.allCases))
        #expect(books.contains { !$0.errors.isEmpty } && books.contains { !$0.boneyard.isEmpty })
        #expect(runs.contains { $0.text.hasPrefix("- ") || $0.text.hasPrefix("#") })
    }

    @Test func theRichBookRoundTrips() throws {
        let book = try RichBook.make()
        let bytes = try BookFormat.verifiedSerialization(of: book)
        #expect(parse(bytes).book == book)
    }

    @Test func serializingDoesNotDependOnTheMachineTimeZone() throws {
        let original = ProcessInfo.processInfo.environment["TZ"]
        defer {
            if let original { setenv("TZ", original, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        var outputs: [Data] = []
        for zone in ["America/Los_Angeles", "Asia/Kolkata"] {
            setenv("TZ", zone, 1)
            NSTimeZone.resetSystemTimeZone()
            try #require(TimeZone.current.identifier == zone)
            outputs.append(BookFormat.serialize(parse(try Fixture.data("complete-example")).book))
        }
        #expect(outputs[0] == outputs[1])
    }

    // MARK: §7.2, refusals

    /// What the model's types can't rule out is refused, never saved differently.
    @Test func aBookBreakingAnInvariantIsRefused() throws {
        var duplicate = try RichBook.make()
        duplicate.boneyard.append(duplicate.scenes[1])
        #expect(throws: VerificationFailure.self) { try BookFormat.verifiedSerialization(of: duplicate) }

        var badID = try RichBook.make()
        badID.scenes[1].id = SceneID(rawValue: "has space")
        #expect(throws: VerificationFailure.self) { try BookFormat.verifiedSerialization(of: badID) }
    }

    /// An empty run has nothing to write, so `Paragraph` drops it and it can't block a save.
    @Test(arguments: [
        [Run("a"), Run("", styles: [.bold]), Run("b")],
        [Run("")],
        [Run("The "), Run("", comments: [CommentID(rawValue: "c1")]), Run("end")],
    ])
    func emptyRunsAreDroppedAndTheBookSaves(runs: [Run]) throws {
        let paragraph = Paragraph(runs)
        #expect(paragraph.runs.allSatisfy { !$0.text.isEmpty })
        #expect(paragraph.text == runs.map(\.text).joined())
        var scene = plainScene(body: [paragraph])
        scene.comments = [Comment(id: CommentID(rawValue: "c1"), color: .red, text: "", created: openedAt)]
        let book = Book(title: "T", scenes: [scene])
        let bytes = try BookFormat.verifiedSerialization(of: book)
        #expect(parse(bytes).book == book.withMaximalRuns)
    }

    @Test func runsThatBecomeEmptyAreDropped() {
        var paragraph = Paragraph([Run("a"), Run("b", styles: [.bold])])
        paragraph.runs[1].text = ""
        #expect(paragraph.runs == [Run("a")])
    }

    /// The reviewer's case: a run's comment id that the scene doesn't list is written
    /// without it, so the bytes are stable but the id is lost. Verification compares books
    /// too, so the save is refused.
    @Test func aLossySerializationIsRefused() throws {
        let commented = Run("letter", comments: [CommentID(rawValue: "ghost")])
        let book = Book(title: "T", scenes: [plainScene(body: [Paragraph([Run("The "), commented])])])
        #expect(parse(BookFormat.serialize(book)).book != book, "precondition: the save would lose the id")
        #expect(throws: VerificationFailure.changed) { try BookFormat.verifiedSerialization(of: book) }
    }

    /// Text the format can't store can't get into the model: the types apply the
    /// character policy, the way the parser does on reading.
    @Test func theModelOnlyHoldsTextTheFormatCanStore() throws {
        var book = try RichBook.make()
        book.title = "Wave\u{2014}\r\nnew"
        book.scenes[1].title = "one\ntwo\u{2028}three 🌊"
        book.scenes[1].body = [[Run("wave 🌊\nline\t\u{201C}q\u{201D}")]]
        book.scenes[1].body[0].runs[0].text += "\u{2026}e\u{301}"
        book.scenes[1].tags = ["", "α", "a\r\nb", "c\u{2028}d\u{85}e"]
        book.scenes[0].comments[0].text = "one\u{2029}two\u{0B}three\u{0C}four"
        book.scenes[1].errors = [ErrorEntry(.line, "  C:\\  "), ErrorEntry(.notice, "x\ny")]
        #expect(book.title == "Wave--\nnew")
        #expect(book.scenes[1].title == "one two three [?]")
        #expect(book.scenes[1].body[0].runs[0].text == "wave [?] line \"q\"...é")
        #expect(book.scenes[1].tags == ["[?]", "a\nb", "c\nd\ne"])
        #expect(book.scenes[0].comments[0].text == "one\ntwo\nthree\nfour")
        #expect(book.scenes[1].errors.map(\.payload) == ["C:\\ ", "x y"])
        let bytes = try BookFormat.verifiedSerialization(of: book)
        #expect(parse(bytes).book == book)
    }

    @Test func entriesTheBookAlreadyHadAreNotNew() throws {
        let book = parse(try SpecExampleTests.damagedBytes()).book
        #expect(book.errorEntries.joined().count == 12)
        #expect(throws: Never.self) { try BookFormat.verifiedSerialization(of: book) }
    }

    // MARK: §7.3, the table

    @Test(arguments: [
        ("Unescaped_ ~ tilde, * star, \\é, **open", "Unescaped\\_ \\~ tilde, \\* star, \\\\é, \\*\\*open"),
        ("- dash\n\n--- rule", "\\- dash\n\n\\--- rule"),
        ("*~~**x**~~*", "***~~x~~***"),
        ("a****b", "ab"),
        ("<br/>\n\n<BR />", "<br>\n\n<br>"),
        ("   indented\twith\ttabs   ", "indented with tabs"),
        (
            "\u{201C}Curly\u{201D} \u{2018}q\u{2019} dash\u{2014}en\u{2013}dots\u{2026}",
            "\"Curly\" 'q' dash--en-dots..."
        ),
        ("cafe\u{301}", "caf\u{E9}"),
        ("wrapped\nparagraph", "wrapped paragraph"),
        ("**a**** b**", "**a b**"),
    ])
    func bodyTextIsCanonicalized(input: String, canonical: String) throws {
        let scene = try onlyScene(file(scene: input))
        #expect(scene.errors.isEmpty, "\(scene.errors)")
        #expect(file(scene) == file(scene: canonical))
    }

    @Test(arguments: [
        (
            "### Comments\n-   c1|GREY| 2026-01-01T00:00:00Z |C0-2 ,  c003-5|\"He\" ,\"fo\"|  text",
            "### Comments\n- c1 | gray | 2026-01-01T00:00:00+00:00 | c0-2, c3-5 | \"He\", \"fo\" | text"
        ),
        (
            "### Comments\n- c1 | red | 2026-01-01T00:00:00Z | Detached | x",
            "### Comments\n- c1 | red | 2026-01-01T00:00:00+00:00 | detached | x"
        ),
        (
            "### Comments\n- c1 | red | 2026-01-01T00:00:00Z | Notes c0-4 | \"Tide\" | x",
            "### Comments\n- c1 | red | 2026-01-01T00:00:00+00:00 | notes c0-4 | \"Tide\" | x"
        ),
        (
            "### Marks\n- highlight green | notes c0-4 | \"Tide\"\n- color red | c0-3 | \"He \"\n- color red | c3-5 | \"fo\"\n"
                + "- color blue | c1-2 | \"e\"\n- color black | c0-1 | \"H\"",
            "### Marks\n- color blue | c1-2 | \"e\"\n- color red | c2-5 | \" fo\"\n- highlight green | notes c0-4 | \"Tide\""
        ),
        (
            "### Unparsed\n- [LINE]   x\n\n### Marks\n\n### Comments\n\n### Notes\n\n### Unparsed\n- [notice] y",
            "### Unparsed\n- [line] x\n- [notice] y"
        ),
    ])
    func entriesAreCanonicalized(input: String, canonical: String) throws {
        let notes = "### Notes\nTide tables."
        let scene = try onlyScene(file(scene: "He found it.\n\n\(notes)\n\n\(input)"))
        #expect(scene.errors.allSatisfy { $0.tag == .line || $0.tag == .notice }, "\(scene.errors)")
        #expect(file(scene) == file(scene: "He found it.\n\n\(notes)\n\n\(canonical)"))
    }

    @Test func metadataAndFrontMatterAreCanonicalized() {
        let input =
            "\u{FEFF}\r\n---\r\nFORMAT: 2\r\nTitle:   My Novel  \r\n\r\n## The *ferry*\r\nModified: 2026-01-01T00:00:00Z\r\n"
            + "ID: a\r\nTAGS: #one,, two , \r\n\r\n\r\n\r\nText.\r\n\r\n\r\n"
        let book = parse(input).book
        #expect(book.errorEntries.joined().isEmpty)
        #expect(
            serialized(book)
                == "---\ntitle: My Novel\nformat: 2\n---\n\n## The ferry\nid: a\nmodified: 2026-01-01T00:00:00+00:00\n"
                + "tags: one, two\n\nText.\n")
        let noTags = parse("## S\nid: a\nmodified: 2026-01-01T00:00:00Z\ntags:\n").book
        #expect(!serialized(noTags).contains("tags"))
    }

    @Test func fragmentedRunsAreWrittenAsMaximalRuns() throws {
        let fragmented = plainScene(body: [[Run("a", styles: [.bold]), Run("b", styles: [.bold]), Run("c")]])
        let scene = try onlyScene(file(fragmented))
        #expect(scene.body == [[Run("ab", styles: [.bold]), Run("c")]])
        #expect(file(fragmented) == file(scene))
    }
}
