import Foundation
import Testing

@testable import SceneItCore

@Suite struct BookValidatorTests {
    private func problems(corrupting target: String, with replacement: String) throws -> [String] {
        let json = try Fixture.text("rich-book").replacingFirst(target, with: replacement)
        return BookValidator.problems(in: try BookCoding.decode(Data(json.utf8))).map(\.description)
    }

    @Test func richFixtureIsValid() throws {
        #expect(BookValidator.problems(in: try RichBook.make()).isEmpty)
    }

    @Test func commentIDMissingFromCommentsIsRejected() throws {
        let problems = try problems(corrupting: #""01JC4K0000000000000000C003""#, with: #""c404""#)
        #expect(
            problems == [
                #"scene "01JC4K00000000000000000003" (boneyard[0]), body[0][0]: "#
                    + #"comment "c404" is not in the scene's comments"#
            ])
    }

    @Test func commentIDFromAnotherSceneIsRejected() throws {
        var book = try RichBook.make()
        let foreign = try #require(book.scenes[0].comments.first?.id)
        book.boneyard[0].notes = [[Run("x", comments: [foreign])]]
        #expect(
            BookValidator.problems(in: book).map(\.description) == [
                #"scene "01JC4K00000000000000000003" (boneyard[0]), notes[0][0]: "#
                    + #"comment "\#(foreign)" is not in the scene's comments"#
            ])
    }

    @Test func lineBreakInTitleIsRejected() throws {
        let problems = try problems(corrupting: #""text" : "The ferry""#, with: #""text" : "The\nferry""#)
        #expect(
            problems == [
                #"scene "01JC4K00000000000000000001" (scenes[0]), title[0]: "#
                    + "the title must be one line, but its text contains a line break"
            ])
    }

    @Test(arguments: ["\\n", "\\r", "\\u2028", "\\u2029"])
    func lineBreakInParagraphIsRejected(lineBreak: String) throws {
        let problems = try problems(corrupting: #""text" : "Rain.""#, with: #""text" : "Ra\#(lineBreak)in.""#)
        #expect(
            problems == [
                #"scene "01JC4K00000000000000000002" (scenes[1]), body[0][0]: "#
                    + "a paragraph's text contains a line break"
            ])
    }

    @Test func emptyRunIsRejected() throws {
        let problems = try problems(corrupting: #""text" : "Rain.""#, with: #""text" : """#)
        #expect(
            problems == [
                #"scene "01JC4K00000000000000000002" (scenes[1]), body[0][0]: a run's text is empty"#
            ])
    }

    @Test func sceneIDsAreUniqueAcrossScenesAndBoneyard() throws {
        let problems = try problems(
            corrupting: #""id" : "01JC4K00000000000000000003""#, with: #""id" : "01JC4K00000000000000000001""#
        )
        #expect(
            problems == [
                #"scene "01JC4K00000000000000000001" (boneyard[0]): "#
                    + #"another scene already has the id "01JC4K00000000000000000001""#
            ])
    }

    @Test func commentIDsAreUniqueWithinAScene() throws {
        var book = try RichBook.make()
        book.scenes[0].comments.append(book.scenes[0].comments[0])
        #expect(
            BookValidator.problems(in: book).map(\.description) == [
                #"scene "01JC4K00000000000000000001" (scenes[0]), comments: "#
                    + #"the id "01JC4K0000000000000000C002" is used by more than one comment"#
            ])
    }

    @Test func everyProblemIsReportedInDocumentOrder() throws {
        var book = try RichBook.make()
        book.scenes[0].title = [Run("")]
        book.scenes[1].body = [[Run("a\nb", comments: [CommentID(rawValue: "x")])]]
        book.boneyard[0].id = book.scenes[0].id
        let problems = BookValidator.problems(in: book)
        #expect(
            problems == [
                .emptyRun(
                    TextLocation(
                        scene: ScenePlace(list: .scenes, index: 0, id: book.scenes[0].id),
                        field: .title, paragraph: 0, run: 0)),
                .lineBreak(
                    TextLocation(
                        scene: ScenePlace(list: .scenes, index: 1, id: book.scenes[1].id),
                        field: .body, paragraph: 0, run: 0)),
                .missingComment(
                    TextLocation(
                        scene: ScenePlace(list: .scenes, index: 1, id: book.scenes[1].id),
                        field: .body, paragraph: 0, run: 0),
                    CommentID(rawValue: "x")),
                .duplicateSceneID(ScenePlace(list: .boneyard, index: 0, id: book.scenes[0].id)),
            ])
    }

    @Test func unreferencedCommentsAreAllowed() throws {
        var book = try RichBook.make()
        book.scenes[1].comments = book.boneyard[0].comments
        #expect(BookValidator.problems(in: book).isEmpty)
    }
}
