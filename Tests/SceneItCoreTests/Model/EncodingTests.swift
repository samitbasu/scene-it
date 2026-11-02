import Foundation
import Testing

@testable import SceneItCore

/// `BookCoding.encode` must never produce a file that loading would refuse.
@Suite struct EncodingRefusesInvalidBooksTests {
    private static func firstBodyRun(_ book: Book) -> TextLocation {
        TextLocation(
            scene: ScenePlace(list: .scenes, index: 1, id: book.scenes[1].id), field: .body, paragraph: 0,
            run: 0)
    }

    private func expectEncodingFails(_ book: Book, with problem: BookProblem) {
        #expect(throws: BookEncodingError.invalid([problem])) { try BookCoding.encode(book) }
    }

    @Test func emptyRun() throws {
        var book = try RichBook.make()
        book.scenes[1].body[0].runs[0].text = ""
        expectEncodingFails(book, with: .emptyRun(Self.firstBodyRun(book)))
    }

    @Test(arguments: lineBreaks)
    func lineBreakInParagraph(lineBreak: String) throws {
        var book = try RichBook.make()
        book.scenes[1].body[0].runs[0].text = "Ra\(lineBreak)in."
        expectEncodingFails(book, with: .lineBreak(Self.firstBodyRun(book)))
    }

    @Test func lineBreakInTitle() throws {
        var book = try RichBook.make()
        book.scenes[0].title = "The\u{2028}ferry"
        expectEncodingFails(
            book, with: .lineBreakInTitle(ScenePlace(list: .scenes, index: 0, id: book.scenes[0].id)))
    }

    @Test func missingCommentID() throws {
        var book = try RichBook.make()
        let missing = CommentID(rawValue: "c404")
        book.scenes[1].body[0].runs[0].comments = [missing]
        expectEncodingFails(book, with: .missingComment(Self.firstBodyRun(book), missing))
    }

    @Test func duplicateSceneID() throws {
        var book = try RichBook.make()
        book.boneyard[0].id = book.scenes[0].id
        expectEncodingFails(
            book, with: .duplicateSceneID(ScenePlace(list: .boneyard, index: 0, id: book.scenes[0].id)))
    }

    @Test func duplicateCommentID() throws {
        var book = try RichBook.make()
        book.scenes[0].comments.append(book.scenes[0].comments[0])
        expectEncodingFails(
            book,
            with: .duplicateCommentID(
                ScenePlace(list: .scenes, index: 0, id: book.scenes[0].id), book.scenes[0].comments[0].id))
    }

    @Test func errorListsEveryProblem() throws {
        var book = try RichBook.make()
        book.scenes[1].body[0].runs[0].text = ""
        book.boneyard[0].id = book.scenes[0].id
        let error = try #require(throws: BookEncodingError.self) { try BookCoding.encode(book) }
        #expect(
            error.description == """
                the book is invalid:
                - scene "01JC4K00000000000000000002" (scenes[1]), body[0][0]: a run's text is empty
                - scene "01JC4K00000000000000000001" (boneyard[0]): another scene already has the id \
                "01JC4K00000000000000000001"
                """)
    }
}

/// Decision 0013: a run's black is the absence of a color.
@Suite struct BlackIsNoColorTests {
    @Test func blackDecodesAsNoColorAndIsNotWrittenBack() throws {
        let json = try Fixture.text("rich-book").replacingFirst(
            #""color" : "gray","#, with: #""color" : "black","#)
        var expected = try RichBook.make()
        #expect(expected.scenes[0].notes[0].runs[0].color == .gray, "precondition: the replaced run")
        expected.scenes[0].notes[0].runs[0].color = nil

        let decoded = try BookCoding.decode(Data(json.utf8))
        #expect(decoded == expected)
        let reencoded = try BookCoding.encode(decoded)
        #expect(reencoded == (try BookCoding.encode(expected)))
    }

    @Test func runsHaveNoBlackButCommentsDo() {
        #expect(TextColor(rawValue: "black") == nil)
        #expect(TextColor(PaletteColor.black) == nil)
        #expect(TextColor(PaletteColor.purple) == .purple)
        #expect(PaletteColor.allCases.count == TextColor.allCases.count + 1)
    }
}

@Suite struct ByteStabilityTests {
    @Test func negativeZeroRateIsStoredAsZero() throws {
        let rate = try #require(SpeechRate(exactly: -0.0))
        #expect(rate.value.sign == .plus)
        #expect(SpeechRate(clamping: -0.0).value.sign == .plus)
        #expect(SpeechRate(clamping: -1).value.sign == .plus)
    }

    @Test func idsCompareByBytesNotCanonicalEquivalence() {
        let composed = CommentID(rawValue: "caf\u{E9}")
        let decomposed = CommentID(rawValue: "cafe\u{301}")
        #expect(composed.rawValue == decomposed.rawValue, "precondition: String == is canonical")
        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
        #expect(decomposed < composed)
    }

    @Test func commentIDsAreWrittenInByteOrder() throws {
        struct CommentsOnly: Decodable { let comments: [String] }
        let ids = ["b", "\u{E9}", "B", "cafe\u{301}", "caf\u{E9}"]
        let run = Run("x", comments: Set(ids.map(CommentID.init)))
        let written = try JSONDecoder().decode(
            CommentsOnly.self, from: try BookCoding.makeEncoder().encode(run))
        #expect(
            written.comments.map { Array($0.utf8) }
                == ["B", "b", "cafe\u{301}", "caf\u{E9}", "\u{E9}"].map { Array($0.utf8) })
    }
}
