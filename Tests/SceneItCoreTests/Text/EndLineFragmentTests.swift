import AppKit
import Testing

@testable import SceneItCore

@MainActor
struct EndLineFragmentTests {
    /// #102: TextKit puts the end line straight under a final empty paragraph; it goes one empty
    /// paragraph's spacing before lower, as tall as the empty line, and the fragment reaches it.
    @Test func afterAFinalEmptyParagraphTheEndLineCopiesItSpacedBefore() throws {
        let text = RunCodec.attributedString(forBody: [[Run("Hello")], [], []])
        let last = try #require(Layout(text, in: .ours).fragments.last)
        let lines = last.textLineFragments
        try #require(lines.count == 2, "precondition: the empty line and the end line")
        let (empty, end) = (lines[0], lines[1])
        try #require(empty.characterRange.length == 1 && end.characterRange.length == 0, "precondition")
        let theirs = try #require(Layout(text, in: .textKits).fragments.last?.textLineFragments.last)
        let gap = ParagraphRole.doubleSpacingGap
        try #require(
            theirs.typographicBounds.minY < empty.typographicBounds.maxY + 1,
            "precondition: TextKit puts it straight under: \(theirs.typographicBounds)")

        #expect(abs(end.typographicBounds.minY - (empty.typographicBounds.maxY + gap)) < 0.01)
        #expect(end.typographicBounds.height == empty.typographicBounds.height)
        #expect(end.typographicBounds.minX == empty.typographicBounds.minX)
        #expect(end.glyphOrigin == empty.glyphOrigin)
        #expect(
            abs(last.layoutFragmentFrame.height - end.typographicBounds.maxY) < 0.01,
            "\(last.layoutFragmentFrame)")
        #expect(last.textLineFragments.last === end, "the same line each time it's asked for")
    }

    /// Every other ending, and an empty paragraph TextKit lays out without spacing before (as the
    /// moment before the editor restyles it), is laid out exactly as TextKit lays it out.
    @Test(
        arguments: [
            [[Run("Hello")]], [[Run("Hello")], []], [[Run("A")], [], [Run("B")], []], [],
            [[Run("A")], [], [Run("B")]],
        ] as [[Paragraph]])
    func otherwiseTheLinesAreTextKits(_ body: [Paragraph]) throws {
        try expectTextKitsLines(RunCodec.attributedString(forBody: body))
    }

    @Test func aFinalEmptyParagraphWithNoSpacingBeforeKeepsTextKitsEndLine() throws {
        let text = NSMutableAttributedString(
            attributedString: RunCodec.attributedString(forBody: [[Run("Hello")], [], []]))
        let empty = NSRange(location: text.length - 1, length: 1)
        text.addAttribute(.paragraphStyle, value: ParagraphRole.body.paragraphStyle(for: .text), range: empty)
        try expectTextKitsLines(text)
    }

    /// Text typed after the final empty paragraph goes where TextKit puts it: the empty paragraph
    /// no longer reaches down to an end line. (A new final empty paragraph gets one of its own.)
    @Test(arguments: ["x", "\n"])
    func typingAfterTheFinalEmptyParagraphLeavesItAsTextKitLaysItOut(_ typed: String) throws {
        let text = RunCodec.attributedString(forBody: [[Run("Hello")], [], []])
        let ours = Layout(text, in: .ours)
        try #require(ours.fragments.last?.textLineFragments.count == 2, "precondition: an end line")
        let after = ours.type(typed)
        let theirs = Layout(after, in: .textKits).fragments
        let mine = ours.fragments
        try #require(mine.count == theirs.count, "precondition")
        for (fragment, its) in zip(mine.dropLast(), theirs.dropLast()) {
            #expect(fragment.layoutFragmentFrame == its.layoutFragmentFrame)
        }
        #expect(mine.last?.layoutFragmentFrame.minY == theirs.last?.layoutFragmentFrame.minY)
    }

    private func expectTextKitsLines(
        _ text: NSAttributedString, sourceLocation: SourceLocation = #_sourceLocation
    )
        throws
    {
        let ours = Layout(text, in: .ours).fragments
        let theirs = Layout(text, in: .textKits).fragments
        try #require(ours.count == theirs.count, sourceLocation: sourceLocation)
        for (mine, its) in zip(ours, theirs) {
            #expect(mine.layoutFragmentFrame == its.layoutFragmentFrame, sourceLocation: sourceLocation)
            #expect(
                mine.textLineFragments.map(\.typographicBounds)
                    == its.textLineFragments.map(\.typographicBounds),
                sourceLocation: sourceLocation)
        }
    }

    enum Fragments {
        case ours, textKits
    }

    final class Layout: NSObject, NSTextLayoutManagerDelegate {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let storage: NSTextStorage

        init(_ text: NSAttributedString, in fragments: Fragments) {
            storage = NSTextStorage(attributedString: text)
            super.init()
            if fragments == .ours { layout.delegate = self }
            content.addTextLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(width: 468, height: 10_000))
            container.lineFragmentPadding = 0
            layout.textContainer = container
            content.textStorage = storage
        }

        /// Types `typed` at the end, styled as the editor styles it, and returns the text.
        func type(_ typed: String) -> NSAttributedString {
            content.performEditingTransaction {
                storage.append(
                    NSAttributedString(string: typed, attributes: ParagraphRole.body.typingAttributes))
                ParagraphRole.body.styleParagraphs(
                    of: storage, around: NSRange(location: 0, length: storage.length))
            }
            return NSAttributedString(attributedString: storage)
        }

        var fragments: [NSTextLayoutFragment] {
            var fragments: [NSTextLayoutFragment] = []
            layout.enumerateTextLayoutFragments(
                from: layout.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment]
            ) {
                fragments.append($0)
                return true
            }
            return fragments
        }

        func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            EndLineFragment(textElement: textElement, range: textElement.elementRange)
        }
    }
}
