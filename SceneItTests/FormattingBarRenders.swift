import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// The formatting bar (#18): the whole window at 1× and 2× beside the mockup, and the bar and its
/// palettes close up at 3×.
extension WindowRenders {
    /// Bold and purple throughout, italic in part: B on, I mixed, S off, purple on.
    private static let selectedText = "The ferry left at dawn, and the harbor lights"
    private static let barBody: [Paragraph] =
        [
            [
                Run("The ferry left at dawn,", styles: [.bold], color: .purple),
                Run(" and the harbor lights", styles: [.bold, .italic], color: .purple),
                Run(
                    " went out one by one behind her. She had packed in the dark, by feel, the way she used to "
                        + "as a girl when the house was asleep."),
            ]
        ] + formattedBody.dropFirst()

    @Test func formattingBar() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            let scene = try #require(book.openScene)
            book.replaceBody(of: scene, with: Self.barBody)
            let formatting = EditorFormatting(preferences: preferences)
            let window = BookWindow(
                book: book, store: store, preferences: preferences, formatting: formatting,
                mode: .constant(.page))

            let active = try await Self.render(window) { window in
                let page = try #require(Self.page(in: window))
                #expect(window.makeFirstResponder(page))
                page.setSelectedRange(NSRange(location: 0, length: (Self.selectedText as NSString).length))
            }
            #expect(formatting.state(of: .toggle(.bold)) == .on, "precondition: B on")
            #expect(formatting.state(of: .toggle(.italic)) == .mixed, "precondition: I mixed")
            try Self.write(
                active, name: "final-format-bar", caption: "The bar: selection bold, part italic, purple",
                to: output)
            try Self.png(Self.barCloseUp(active.triple)).write(
                to: output.appending(path: "final-format-bar-close-up@3x.png"))

            let inactive = try await Self.render(window) { window in
                let title = try #require(
                    subviewTree(of: window.contentView).compactMap { $0 as? NSTextField }.first {
                        $0.placeholderString == WindowWording.untitledScene
                    })
                #expect(window.makeFirstResponder(title))
            }
            #expect(formatting.selection == nil, "precondition: the bar is inactive")
            try Self.write(
                inactive, name: "final-format-bar-inactive",
                caption: "The title field has the focus: the bar is dimmed", to: output,
                beside: "05-notes-tab-focus-bars.png")
            try Self.png(Self.barCloseUp(inactive.triple)).write(
                to: output.appending(path: "final-format-bar-inactive-close-up@3x.png"))

            try Self.writePalettes(book, preferences, to: output)
        }
    }

    /// The bar and the toolbar above it, cut from a 3× render.
    private static func barCloseUp(_ rep: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let image = try #require(rep.cgImage)
        let crop = CGRect(x: 0, y: 0, width: 520 * 3, height: 110 * 3)
        return NSBitmapImageRep(cgImage: try #require(image.cropping(to: crop)))
    }

    /// Both palettes, the selection's color ringed (purple text, green highlight), at 3×.
    private static func writePalettes(_ book: AppOpenBook, _ preferences: AppPreferences, to output: URL)
        throws
    {
        let formatting = EditorFormatting(preferences: preferences)
        let editor = SceneTextEditor(
            book: book, part: .body, formatting: formatting, comments: CommentSelection())
        formatting.show(SelectionFormatting([Run("x", color: .purple, highlight: .green)]), from: editor)
        for (name, kind) in [("text", PaletteKind.textColor), ("highlight", .highlight)] {
            let view = NSHostingView(
                rootView: PaletteView(formatting: formatting, part: .body, kind: kind) {}
                    .background(Color(nsColor: .windowBackgroundColor)))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            try png(bitmap(of: view, scale: 3)).write(
                to: output.appending(path: "final-palette-\(name)@3x.png"))
        }
    }
}
