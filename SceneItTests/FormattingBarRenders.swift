import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// The formatting bar's candidate looks (#18), for the owner's pick: the whole window at 1× and
/// 2× beside the mockup, and the bar and its palettes close up at 3×.
extension WindowRenders {
    private struct Candidate {
        let name: String
        let caption: String
        let look: FormattingBarLook
    }

    private static func look(_ change: (inout FormattingBarLook) -> Void) -> FormattingBarLook {
        var look = FormattingBarLook.recommended
        change(&look)
        return look
    }

    private static let candidates: [Candidate] = [
        Candidate(
            name: "a1-plain", caption: "a1 (recommended): plain glyph buttons, as in the mockup",
            look: .recommended),
        Candidate(
            name: "a2-bordered", caption: "a2: bordered buttons", look: look { $0.buttons = .bordered }),
        Candidate(
            name: "a3-segmented", caption: "a3: B I S as one segmented group",
            look: look { $0.buttons = .segmented }),
        Candidate(name: "b2-tint", caption: "b2: state as a blue tint", look: look { $0.stateMark = .tint }),
        Candidate(
            name: "b3-underline", caption: "b3: state as an underline",
            look: look { $0.stateMark = .underline }),
        Candidate(
            name: "c2-split", caption: "c2: color buttons as split buttons",
            look: look { $0.colorButton = .split }),
        Candidate(
            name: "d2-symbols", caption: "d2: SF Symbols for color and highlight",
            look: look { $0.colorGlyph = .symbol }),
    ]

    /// Bold and purple throughout, italic in part: B on, I mixed, S off, purple on.
    private static let selectedText = "The ferry left at dawn, and the harbor lights"
    private static let candidateBody: [Paragraph] =
        [
            [
                Run("The ferry left at dawn,", styles: [.bold], color: .purple),
                Run(" and the harbor lights", styles: [.bold, .italic], color: .purple),
                Run(
                    " went out one by one behind her. She had packed in the dark, by feel, the way she used to "
                        + "as a girl when the house was asleep."),
            ]
        ] + formattedBody.dropFirst()

    @Test func formattingBarCandidates() async throws {
        let output = try #require(renderFolder).appending(
            path: "format-bar-candidates", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            let scene = try #require(book.openScene)
            book.replaceBody(of: scene, with: Self.candidateBody)
            let selection = NSRange(location: 0, length: (Self.selectedText as NSString).length)
            for candidate in Self.candidates {
                let formatting = PageFormatting(preferences: preferences)
                let window = BookWindow(
                    book: book, store: store, preferences: preferences, formatting: formatting,
                    mode: .constant(.page)
                )
                .environment(\.formattingBarLook, candidate.look)
                let renders = try await Self.render(window) { window in
                    let page = try #require(Self.page(in: window))
                    #expect(window.makeFirstResponder(page))
                    page.setSelectedRange(selection)
                }
                #expect(formatting.state(of: .toggle(.bold)) == .on, "precondition: B on")
                #expect(formatting.state(of: .toggle(.italic)) == .mixed, "precondition: I mixed")
                try Self.write(
                    renders, name: candidate.name,
                    caption: "\(candidate.caption); selection bold, part italic, purple",
                    to: output)
                try Self.png(Self.barCloseUp(renders.triple)).write(
                    to: output.appending(path: "\(candidate.name)-bar@3x.png"))
            }

            let formatting = PageFormatting(preferences: preferences)
            let inactive = try await Self.render(
                BookWindow(
                    book: book, store: store, preferences: preferences, formatting: formatting,
                    mode: .constant(.page))
            ) { window in
                let title = try #require(
                    subviewTree(of: window.contentView).compactMap { $0 as? NSTextField }.first {
                        $0.placeholderString == WindowWording.untitledScene
                    })
                #expect(window.makeFirstResponder(title))
            }
            #expect(formatting.selection == nil, "precondition: the bar is inactive")
            try Self.write(
                inactive, name: "inactive-title-focused",
                caption: "a1, the title field has the focus: the bar is inactive", to: output,
                beside: "05-notes-tab-focus-bars.png")
            try Self.png(Self.barCloseUp(inactive.triple)).write(
                to: output.appending(path: "inactive-title-focused-bar@3x.png"))

            try Self.writePalettes(preferences, to: output)
        }
    }

    /// The bar and the toolbar above it, cut from a 3× render.
    private static func barCloseUp(_ rep: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let image = try #require(rep.cgImage)
        let crop = CGRect(x: 0, y: 0, width: 520 * 3, height: 110 * 3)
        return NSBitmapImageRep(cgImage: try #require(image.cropping(to: crop)))
    }

    /// Each palette layout for both palettes, the selection's color ringed (purple text, green
    /// highlight), at 3×.
    private static func writePalettes(_ preferences: AppPreferences, to output: URL) throws {
        let formatting = PageFormatting(preferences: preferences)
        formatting.show(SelectionFormatting([Run("x", color: .purple, highlight: .green)]))
        for layout in FormattingBarLook.Palette.allCases {
            for (kind, commands) in [
                ("text", FormattingCommand.textColors), ("highlight", FormattingCommand.highlights),
            ] {
                let view = NSHostingView(
                    rootView: PaletteView(formatting: formatting, commands: commands, layout: layout) {}
                        .background(Color(nsColor: .windowBackgroundColor)))
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                let name = layout == .row ? "c-palette-row" : "c-palette-grid"
                try png(bitmap(of: view, scale: 3)).write(
                    to: output.appending(path: "\(name)-\(kind)@3x.png"))
            }
        }
    }
}
