import AppKit
import Testing

@testable import SceneItCore

private let noted = CommentID(rawValue: "01JC4K0000000000000000NOTE")
private let other = CommentID(rawValue: "01JC4K0000000000000000OTHR")

/// What a new comment covers (PLAN §8.1), where a comment is in the page's text, and the
/// attribute edits that add and remove one.
@Suite
struct CommentRangesTests {
    private let text = RunCodec.attributedString(
        forBody: [
            [
                Run("The "), Run("letter", comments: [noted]), Run(" waited", comments: [noted, other]),
                Run("."),
            ],
            [], [Run("Dawn", comments: [noted])],
        ])

    @Test func aSelectionIsCommentedAsSelectedLessRangesOfOnlyLineBreaks() {
        #expect(
            text.commentRanges(selecting: [NSRange(location: 4, length: 6)]) == [
                NSRange(location: 4, length: 6)
            ])
        #expect(
            text.commentRanges(selecting: [NSRange(location: 18, length: 1), NSRange(location: 0, length: 3)])
                == [NSRange(location: 0, length: 3)], "\"\\n\" alone carries no comment")
        #expect(text.commentRanges(selecting: [NSRange(location: 18, length: 2)]).isEmpty)
    }

    /// With nothing selected, the word the caret is in or just after; beside no word, nothing.
    @Test func noSelectionCommentsTheWordAtTheCaret() {
        let word = NSRange(location: 4, length: 6)
        #expect((text.string as NSString).substring(with: word) == "letter", "precondition")
        for caret in [4, 7, 10] {
            #expect(
                text.commentRanges(selecting: [NSRange(location: caret, length: 0)]) == [word], "\(caret)")
        }
        #expect(
            text.commentRanges(selecting: [NSRange(location: 0, length: 0)]) == [
                NSRange(location: 0, length: 3)
            ])
        #expect(text.commentRanges(selecting: [NSRange(location: 19, length: 0)]).isEmpty, "an empty line")
        #expect(
            NSAttributedString(string: "").commentRanges(selecting: [NSRange(location: 0, length: 0)]).isEmpty
        )
        #expect(
            NSAttributedString(string: " . ").commentRanges(selecting: [NSRange(location: 1, length: 0)])
                .isEmpty)
    }

    @Test func aCommentsRangesAreItsStretchesJoinedWhereTheyMeet() {
        #expect(
            text.ranges(commentedBy: noted) == [
                NSRange(location: 4, length: 13), NSRange(location: 20, length: 4),
            ])
        #expect(text.ranges(commentedBy: other) == [NSRange(location: 10, length: 7)])
        #expect(text.ranges(commentedBy: CommentID(rawValue: "none")).isEmpty)
    }

    @Test func anEditAddsOrRemovesOneCommentAndKeepsTheFormat() {
        let bold = RunCodec.attributedString(forBody: [
            [Run("x", styles: [.bold], color: .red, comments: [other])]
        ])
        let attributes = bold.attributes(at: 0, effectiveRange: nil)
        let added = CommentEdit.add(noted).applied(to: attributes, in: .body)
        #expect(
            RunFormat(added) == RunFormat(Run("x", styles: [.bold], color: .red, comments: [other, noted])))
        let removed = CommentEdit.remove(other).applied(to: added, in: .body)
        #expect(RunFormat(removed) == RunFormat(Run("x", styles: [.bold], color: .red, comments: [noted])))
    }
}
