import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// The Notes tab as the owner picked it (#19), beside mockup 05: with the notes focused, so the
/// compact bar is the active one, and with the page focused, so it's dimmed.
extension WindowRenders {
    private static let notesMockup = "05-notes-tab-focus-bars.png"

    /// Mockup 05's notes.
    private static let sampleNotes: [Paragraph] = [
        [Run("Check the tide tables: would a ferry really leave at dawn in March?")],
        [Run("Who kept the mother's letter all these years? "), Run("Decide before scene 3.", color: .red)],
        [Run("Mara should notice the blue house before she reaches it.")],
    ]

    @Test func notesTab() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            let scene = try #require(book.openScene)
            book.replaceNotes(of: scene, with: Self.sampleNotes)
            preferences.showRightPanelTab(.notes)
            defer { preferences.showRightPanelTab(.comments) }
            for focus in [TextPart.notes, .body] {
                let formatting = EditorFormatting(preferences: preferences)
                let window = BookWindow(
                    book: book, store: store, preferences: preferences, formatting: formatting,
                    mode: .constant(.page))
                let renders = try await Self.render(window) { window in
                    let editor: NSTextView? =
                        switch focus {
                        case .notes:
                            subviewTree(of: window.contentView).compactMap { $0 as? SceneTextView }
                                .first { !($0 is ManuscriptTextView) }
                        case .body: Self.page(in: window)
                        }
                    let view = try #require(editor)
                    #expect(window.makeFirstResponder(view))
                    view.setSelectedRange(NSRange(location: 0, length: 0))
                }
                #expect(formatting.active?.part == focus, "precondition: the focused editor's bar is active")
                let name = focus == .notes ? "final-notes-tab" : "final-notes-tab-inactive"
                let caption =
                    focus == .notes
                    ? "The Notes tab, the notes focused"
                    : "The Notes tab, the page focused: the compact bar dimmed"
                try Self.write(renders, name: name, caption: caption, to: output, beside: Self.notesMockup)
                try Self.png(Self.panelCloseUp(renders.double)).write(
                    to: output.appending(path: "\(name)-close-up@2x.png"))
            }
        }
    }

    /// The right panel's top and the desk beside it, cut from a 2× render.
    private static func panelCloseUp(_ rep: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let image = try #require(rep.cgImage)
        let width = WindowMetrics.panelWidth + 330
        let crop = CGRect(x: (windowSize.width - width) * 2, y: 0, width: width * 2, height: 330 * 2)
        return NSBitmapImageRep(cgImage: try #require(image.cropping(to: crop)))
    }
}
