import AppKit
import Testing

@testable import SceneItCore

@Suite struct DisplayAttributesTests {
    private static let faces: [(Set<TextStyle>, String)] = [
        ([], "TimesNewRomanPSMT"),
        ([.bold], "TimesNewRomanPS-BoldMT"),
        ([.italic], "TimesNewRomanPS-ItalicMT"),
        ([.bold, .italic], "TimesNewRomanPS-BoldItalicMT"),
    ]

    @Test(arguments: [ParagraphRole.body, .notes])
    func fontsResolveToTimesNewRomanFaces(role: ParagraphRole) {
        for (styles, name) in Self.faces {
            let font = role.font(styles)
            #expect(font.fontName == name)
            #expect(font.familyName == ParagraphRole.fontFamily)
            #expect(font.pointSize == 12)
            #expect(TextStyle.styles(of: font) == styles)
        }
        #expect(role.font([.strike]) == role.font([]))
    }

    @Test func theOutputHeadingIsBoldTimesNewRoman18() {
        #expect(ParagraphRole.title.font([]).fontName == "TimesNewRomanPS-BoldMT")
        #expect(ParagraphRole.title.font([.italic]).fontName == "TimesNewRomanPS-BoldItalicMT")
        #expect(ParagraphRole.title.font([]).pointSize == 18)
    }

    @Test func paragraphStylesFollowTheRole() {
        let body = ParagraphRole.body.paragraphStyle
        #expect(body.lineSpacing == ParagraphRole.doubleSpacingGap, "double spacing, below the line")
        #expect(body.firstLineHeadIndent == 36)
        #expect(ParagraphRole.title.paragraphStyle == NSParagraphStyle.default)
        let notes = ParagraphRole.notes.paragraphStyle
        #expect(notes.paragraphSpacing == 6, "6 pt between the notes' paragraphs (#19)")
        let single = NSMutableParagraphStyle()
        single.paragraphSpacing = 6
        #expect(notes == single, "and otherwise single-spaced, with no indent")
    }

    /// The notes as shown, gap included, save exactly as the same text shown without it.
    @Test func theNotesParagraphGapLeavesWhatIsSavedUnchanged() throws {
        let notes: [Paragraph] = [[Run("One", styles: [.bold])], [Run("Two", color: .red)]]
        let shown = RunCodec.attributedString(forNotes: notes)
        let ungapped = NSMutableAttributedString(attributedString: shown)
        ungapped.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: ungapped.length))
        func gap(_ text: NSAttributedString) -> CGFloat? {
            (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .paragraphSpacing
        }
        #expect(gap(shown) == 6, "precondition: the notes show the gap")
        #expect(gap(ungapped) == nil, "precondition: the other has none")
        var ids = IDGenerator<SystemRandomNumberGenerator>.system
        let id = ids.sceneID()
        func saved(_ text: NSAttributedString) throws -> Data {
            let scene = BookScene(
                id: id, modified: Timestamp(secondsSince1970: 1_700_000_000, offset: .zero), title: "One",
                notes: RunCodec.notes(from: text))
            return try BookFormat.verifiedSerialization(of: Book(title: "Novel", scenes: [scene]))
        }
        #expect(try saved(shown) == saved(ungapped))
    }

    @Test(arguments: [(Editor.body, ParagraphRole.body), (.notes, .notes)])
    func loadingAppliesTheRoleIncludingToBreaks(editor: Editor, role: ParagraphRole) throws {
        let text = editor.load([[Run("a")], [], [Run("b")]])
        try #require(text.string == "a\n\nb")
        for offset in 0..<text.length {
            let attributes = text.attributes(at: offset, effectiveRange: nil)
            #expect(attributes[.font] as? NSFont == role.font([]))
            let content = ParagraphContent(ofParagraphAt: offset, in: text.string as NSString)
            #expect(
                content == (offset == 2 ? .empty : .text),
                "precondition: the empty paragraph is the second break")
            #expect(attributes[.paragraphStyle] as? NSParagraphStyle == role.paragraphStyle(for: content))
        }
    }

    @Test func loadingSetsDisplayColorsAndPaletteNames() throws {
        let colors: [TextColor?] = [nil] + TextColor.allCases
        let runs = colors.enumerated().map { index, color in
            Run("x", color: color, highlight: HighlightColor.allCases[index % HighlightColor.allCases.count])
        }
        let text = RunCodec.attributedString(forNotes: [Paragraph(runs)])
        for (offset, run) in runs.enumerated() {
            let attributes = text.attributes(at: offset, effectiveRange: nil)
            #expect(attributes[.foregroundColor] as? NSColor == PaletteColor(run.color).nsColor)
            #expect(attributes[.textColor] as? String == run.color?.rawValue)
            #expect(attributes[.backgroundColor] as? NSColor == run.highlight?.nsColor)
            #expect(attributes[.highlight] as? String == run.highlight?.rawValue)
        }
    }

    @Test func strikeIsAStrikethroughStyle() {
        let text = RunCodec.attributedString(forNotes: [[Run("x", styles: [.strike]), Run("y")]])
        #expect(
            text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int
                == NSUnderlineStyle.single.rawValue)
        #expect(text.attribute(.strikethroughStyle, at: 1, effectiveRange: nil) == nil)
    }

    @Test func paletteHexValuesMatchThePlan() throws {
        let expected: [(NSColor, UInt32)] = [
            (PaletteColor.black.nsColor, 0x000000), (PaletteColor.purple.nsColor, 0x7B2FBE),
            (PaletteColor.red.nsColor, 0xC62828), (PaletteColor.blue.nsColor, 0x1E5BC6),
            (PaletteColor.green.nsColor, 0x2E7D32), (PaletteColor.gray.nsColor, 0x757575),
            (PaletteColor.pink.nsColor, 0xD81B7A),
            (HighlightColor.purple.nsColor, 0xE9DDF7), (HighlightColor.red.nsColor, 0xF8D7D7),
            (HighlightColor.blue.nsColor, 0xD7E4F8), (HighlightColor.green.nsColor, 0xD9EDDA),
            (HighlightColor.gray.nsColor, 0xE6E6E6), (HighlightColor.pink.nsColor, 0xF8D5E7),
        ]
        #expect(expected.count == PaletteColor.allCases.count + HighlightColor.allCases.count)
        for (color, hex) in expected {
            let srgb = try #require(color.usingColorSpace(.sRGB))
            #expect(srgb.colorSpace == .sRGB)
            let channels = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent].map {
                Int(($0 * 255).rounded())
            }
            #expect(channels == [Int(hex >> 16), Int((hex >> 8) & 0xFF), Int(hex & 0xFF)])
        }
    }

    @Test func paletteAndTextColorConvertBothWays() {
        for palette in PaletteColor.allCases {
            #expect(PaletteColor(TextColor(palette)) == palette)
        }
        #expect(TextColor(PaletteColor(nil)) == nil)
    }

    @Test func novelAttributesAreTypedInAttributedString() throws {
        let ids: Set<CommentID> = [CommentID(rawValue: "a"), CommentID(rawValue: "b")]
        let source = RunCodec.attributedString(
            forNotes: [[Run("plain"), Run("marked", color: .pink, highlight: .gray, comments: ids)]])
        let typed = try AttributedString(source, including: \.novel)
        let marked = try #require(typed.runs.first { $0.comments != nil })
        #expect(String(typed[marked.range].characters) == "marked")
        #expect(marked.comments == ids)
        #expect(marked.textColor == .pink)
        #expect(marked.highlight == .gray)
        #expect(marked.appKit.font == ParagraphRole.notes.font([]))
        let back = try NSAttributedString(typed, including: \.novel)
        #expect(RunCodec.notes(from: back) == RunCodec.notes(from: source))
    }
}
