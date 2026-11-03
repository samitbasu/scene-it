import AppKit
import Testing

@testable import SceneItCore

@Suite struct FormattingTests {
    private static let noted = CommentID(rawValue: "01JC4K00000000000000000NTD")

    @Test func aStyleIsOnOffOrMixedOverTheSelection() {
        let bold = Run("a", styles: [.bold])
        let plain = Run("b")
        #expect(SelectionFormatting([bold]).state(of: .toggle(.bold)) == .on)
        #expect(SelectionFormatting([plain]).state(of: .toggle(.bold)) == .off)
        #expect(SelectionFormatting([bold, plain]).state(of: .toggle(.bold)) == .mixed)
        #expect(SelectionFormatting([bold, plain]).state(of: .toggle(.italic)) == .off)
        #expect(SelectionFormatting([Run]()).state(of: .toggle(.bold)) == .off, "no text: nothing is on")
    }

    @Test func aColorIsOnOnlyWhereTheSelectionHasThatColor() {
        let purple = Run("a", color: .purple)
        let plain = Run("b")
        #expect(SelectionFormatting([purple]).state(of: .textColor(.purple)) == .on)
        #expect(SelectionFormatting([purple]).state(of: .textColor(.red)) == .off)
        #expect(SelectionFormatting([plain]).state(of: .textColor(.black)) == .on, "no color is black")
        #expect(SelectionFormatting([purple, plain]).state(of: .textColor(.purple)) == .mixed)
        #expect(SelectionFormatting([purple, plain]).state(of: .textColor(.black)) == .mixed)
    }

    @Test func aHighlightIsOnOnlyWhereTheSelectionHasIt() {
        let green = Run("a", highlight: .green)
        let plain = Run("b")
        #expect(SelectionFormatting([green]).state(of: .highlight(.green)) == .on)
        #expect(SelectionFormatting([plain]).state(of: .highlight(nil)) == .on, "None")
        #expect(SelectionFormatting([green, plain]).state(of: .highlight(.green)) == .mixed)
        #expect(SelectionFormatting([green]).state(of: .highlight(.blue)) == .off)
    }

    @Test func aToggleTurnsOffOnlyWhenTheWholeSelectionIsOn() {
        let bold = Run("a", styles: [.bold])
        let plain = Run("b")
        #expect(FormattingCommand.toggle(.bold).edit(for: SelectionFormatting([bold])) == .remove(.bold))
        #expect(FormattingCommand.toggle(.bold).edit(for: SelectionFormatting([plain])) == .add(.bold))
        #expect(
            FormattingCommand.toggle(.bold).edit(for: SelectionFormatting([bold, plain])) == .add(.bold),
            "mixed turns on")
    }

    @Test func blackAndNoneRemoveTheColorAndHighlight() {
        let any = SelectionFormatting([Run("a", color: .red, highlight: .pink)])
        #expect(FormattingCommand.textColor(.black).edit(for: any) == .color(nil))
        #expect(
            FormattingCommand.textColor(.red).edit(for: any) == .color(.red), "a color applies, never toggles"
        )
        #expect(FormattingCommand.highlight(nil).edit(for: any) == .highlight(nil))
        #expect(FormattingCommand.highlight(.pink).edit(for: any) == .highlight(.pink))
    }

    @Test func anEditChangesOnlyWhatItNames() {
        let run = Run("letter", styles: [.italic], color: .red, highlight: .green, comments: [Self.noted])
        #expect(
            FormatEdit.add(.bold).applied(to: run)
                == Run(
                    "letter", styles: [.italic, .bold], color: .red, highlight: .green, comments: [Self.noted]
                ))
        #expect(
            FormatEdit.remove(.italic).applied(to: run)
                == Run("letter", color: .red, highlight: .green, comments: [Self.noted]))
        #expect(
            FormatEdit.color(nil).applied(to: run)
                == Run("letter", styles: [.italic], highlight: .green, comments: [Self.noted]))
        #expect(
            FormatEdit.highlight(.blue).applied(to: run)
                == Run("letter", styles: [.italic], color: .red, highlight: .blue, comments: [Self.noted]))
    }

    /// The page holds `NSColor`s and palette names together, as the codec writes them, so what
    /// an edit does to attributes reads back as the same edit to the run.
    @Test func anEditToAttributesIsTheCodecsRendering() {
        let run = Run("letter", styles: [.italic], color: .red, comments: [Self.noted])
        let edits: [FormatEdit] = [
            .add(.bold), .add(.strike), .remove(.italic), .color(.blue), .color(nil), .highlight(.pink),
            .highlight(nil),
        ]
        for edit in edits {
            let before = RunCodec.attributedString(forBody: [[run]])
            let attributes = edit.applied(to: before.attributes(at: 0, effectiveRange: nil), in: .body)
            let after = NSAttributedString(string: run.text, attributes: attributes)
            #expect(RunCodec.body(from: after) == [[edit.applied(to: run)]], "\(edit)")
            #expect(
                after.isEqual(to: RunCodec.attributedString(forBody: [[edit.applied(to: run)]])), "\(edit)")
        }
        let blue = FormatEdit.color(.blue).applied(to: [:], in: .body)
        #expect(blue[.foregroundColor] as? NSColor == PaletteColor.blue.nsColor)
        #expect(blue[.textColor] as? String == "blue")
    }

    @Test func aSelectionIgnoresItsLineBreaks() {
        let text = RunCodec.attributedString(forBody: [
            [Run("One", styles: [.bold])], [Run("Two", styles: [.bold])],
        ])
        let all = NSRange(location: 0, length: text.length)
        #expect(text.string == "One\nTwo", "precondition: a plain line break between bold lines")
        #expect(SelectionFormatting(selecting: [all], in: text).state(of: .toggle(.bold)) == .on)
        #expect(
            SelectionFormatting(selecting: [NSRange(location: 3, length: 1)], in: text).state(
                of: .toggle(.bold))
                == .off, "only a line break: no text")
        #expect(
            SelectionFormatting(
                selecting: [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)], in: text)
                == SelectionFormatting([Run("O", styles: [.bold])]), "several ranges")
    }

    @Test func theCaretShowsItsTypingFormat() {
        let typing = FormatEdit.add(.italic).applied(to: ParagraphRole.body.typingAttributes, in: .body)
        #expect(SelectionFormatting(typing: typing).state(of: .toggle(.italic)) == .on)
        #expect(SelectionFormatting(typing: typing).state(of: .toggle(.bold)) == .off)
    }

    @Test func thePalettesListEveryColorInOrder() {
        #expect(
            FormattingCommand.textColors
                == [
                    .textColor(.black), .textColor(.purple), .textColor(.red), .textColor(.blue),
                    .textColor(.green), .textColor(.gray), .textColor(.pink),
                ])
        #expect(FormattingCommand.highlights.first == .highlight(nil))
        #expect(FormattingCommand.highlights.count == HighlightColor.allCases.count + 1)
    }
}
