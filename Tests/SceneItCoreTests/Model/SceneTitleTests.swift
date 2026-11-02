import Foundation
import Testing

@testable import SceneItCore

@Suite struct SceneTitleTests {
    @Test func aFormattedTitleLoadsAsPlainTextAndSavesAsOnePlainRun() throws {
        let fixture = try Fixture.text("rich-book")
        let formatted = try fixture.replacingFirst(
            #""text" : "The station""#,
            with: #""text" : "The "}, {"italic": true, "bold": true, "color": "red", "highlight": "blue", "#
                + #""comments": ["01JC4K0000000000000000C001"], "text" : "station""#)
        let book = try BookCoding.decode(Data(formatted.utf8))
        #expect(book.scenes[1].title == "The station")
        #expect(book == (try RichBook.make()))
        #expect(String(decoding: try BookCoding.encode(book), as: UTF8.self) == fixture)
    }

    @Test func anEmptyTitleIsAnEmptyArray() throws {
        let json = String(decoding: try BookCoding.makeEncoder().encode(SceneTitle("")), as: UTF8.self)
        #expect(json == "[\n\n]")
        for empty in ["[]", #"[{"text": ""}]"#] {
            #expect(try JSONDecoder().decode(SceneTitle.self, from: Data(empty.utf8)) == "")
        }
    }

    @Test func aTitleIsOnePlainRun() throws {
        let json = String(decoding: try JSONEncoder().encode(SceneTitle("The ferry")), as: UTF8.self)
        #expect(json == #"[{"text":"The ferry"}]"#)
    }

    @Test(arguments: lineBreaks)
    func pastedSeparatorsBecomeSpaces(separator: String) {
        #expect(SceneTitle(pasted: "The\(separator)ferry\(separator)") == "The ferry ")
    }

    @Test func pastedObjectReplacementCharactersAreRemoved() {
        #expect(SceneTitle(pasted: "\u{FFFC}The\u{FFFC} ferry") == "The ferry")
    }

    @Test func lineBreaksListsEverySeparator() {
        let scalars = (0...0x10FFFF).compactMap(Unicode.Scalar.init).filter { Character($0).isLineBreak }
        #expect(Set(lineBreaks.flatMap(\.unicodeScalars)) == Set(scalars))
        #expect(lineBreaks.allSatisfy { $0.count == 1 && $0.first!.isLineBreak })
    }

    @Test func commentIDsCollectsEveryRunsIDs() {
        let (a, b) = (CommentID(rawValue: "a"), CommentID(rawValue: "b"))
        let paragraphs: [Paragraph] = [
            [Run("x", comments: [a])], [], [Run("y"), Run("z", comments: [a, b])],
        ]
        #expect(Paragraph.commentIDs(in: paragraphs) == [a, b])
        #expect(Paragraph.commentIDs(in: []).isEmpty)
    }
}
