import Foundation
import Testing

@testable import SceneItCore

@Suite struct SceneTitleTests {
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
