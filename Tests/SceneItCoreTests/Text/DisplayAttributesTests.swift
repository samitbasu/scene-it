import AppKit
import Testing

@testable import SceneItCore

@MainActor @Suite struct DisplayAttributesTests {
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
            #expect(role.styles(of: font) == styles.subtracting([.strike]))
        }
        #expect(role.font([.strike]) == role.font([]))
    }

    @Test func theTitleIsBoldTimesNewRoman18() {
        #expect(ParagraphRole.title.font([]).fontName == "TimesNewRomanPS-BoldMT")
        #expect(ParagraphRole.title.font([.italic]).fontName == "TimesNewRomanPS-BoldItalicMT")
        #expect(ParagraphRole.title.font([]).pointSize == 18)
    }

    @Test func paragraphStylesFollowTheRole() {
        let body = ParagraphRole.body.paragraphStyle
        #expect(body.lineHeightMultiple == 2)
        #expect(body.firstLineHeadIndent == 36)
        for role in [ParagraphRole.title, .notes] {
            #expect(role.paragraphStyle == NSParagraphStyle.default)
        }
    }

    @Test func loadingAppliesEachParagraphsRoleIncludingItsBreak() throws {
        let text = RunCodec.attributedString(for: ScenePage(title: [Run("T")], body: [[Run("b")], []]))
        try #require(text.string == "T\nb\n")
        let roles: [ParagraphRole] = [.title, .title, .body, .body]
        for (offset, role) in roles.enumerated() {
            let attributes = text.attributes(at: offset, effectiveRange: nil)
            #expect(attributes[.font] as? NSFont == role.font([]))
            #expect(attributes[.paragraphStyle] as? NSParagraphStyle == role.paragraphStyle)
        }
        let notes = RunCodec.attributedString(forNotes: [[Run("n")]])
        #expect(notes.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle == .default)
        #expect(notes.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == ParagraphRole.notes.font([]))
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
