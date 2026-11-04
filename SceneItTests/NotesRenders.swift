import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// The Notes tab's candidates (#19), beside mockup 05: the compact bar's layout, and the notes'
/// type size and padding. Each with the notes focused, so the compact bar is the active one.
extension WindowRenders {
    private static let notesMockup = "05-notes-tab-focus-bars.png"

    /// Mockup 05's notes.
    private static let sampleNotes: [Paragraph] = [
        [Run("Check the tide tables: would a ferry really leave at dawn in March?")],
        [Run("Who kept the mother's letter all these years? "), Run("Decide before scene 3.", color: .red)],
        [Run("Mara should notice the blue house before she reaches it.")],
    ]

    private struct NotesLook {
        let name: String
        let caption: String
        /// The candidate's type size; the notes are set at 12 pt, and scaled to show another.
        let pointSize: CGFloat
        let padding: CGSize
        var barLayout = CompactBarLayout.glyphRow
        /// Between paragraphs; the notes have none, and the mockup some.
        var paragraphSpacing: CGFloat = 0
    }

    private static let notesLooks: [NotesLook] = [
        NotesLook(
            name: "notes-bar-A-glyph-row", caption: "Bar A: one row of glyph buttons (recommended)",
            pointSize: 12, padding: CGSize(width: 14, height: 12)),
        NotesLook(
            name: "notes-bar-B-overflow-menu", caption: "Bar B: B I S and a ... menu with the palettes",
            pointSize: 12, padding: CGSize(width: 14, height: 12), barLayout: .overflowMenu),
        NotesLook(
            name: "notes-look-12pt-pad14", caption: "Notes 12 pt, 14 pt padding (recommended)",
            pointSize: 12, padding: CGSize(width: 14, height: 12)),
        NotesLook(
            name: "notes-look-13pt-pad14", caption: "Notes 13 pt, 14 pt padding", pointSize: 13,
            padding: CGSize(width: 14, height: 12)),
        NotesLook(
            name: "notes-look-12pt-pad20", caption: "Notes 12 pt, 20 pt padding", pointSize: 12,
            padding: CGSize(width: 20, height: 18)),
        NotesLook(
            name: "notes-look-13pt-pad20", caption: "Notes 13 pt, 20 pt padding", pointSize: 13,
            padding: CGSize(width: 20, height: 18)),
        NotesLook(
            name: "notes-look-12pt-pad14-spaced",
            caption: "Notes 12 pt, 14 pt padding, 6 pt between paragraphs",
            pointSize: 12, padding: CGSize(width: 14, height: 12), paragraphSpacing: 6),
        NotesLook(
            name: "notes-look-13pt-pad14-spaced",
            caption: "Notes 13 pt, 14 pt padding, 6 pt between paragraphs",
            pointSize: 13, padding: CGSize(width: 14, height: 12), paragraphSpacing: 6),
    ]

    @Test func notesTab() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            let scene = try #require(book.openScene)
            book.replaceNotes(of: scene, with: Self.sampleNotes)
            preferences.showRightPanelTab(.notes)
            defer { preferences.showRightPanelTab(.comments) }
            for look in Self.notesLooks {
                let formatting = EditorFormatting(preferences: preferences)
                let factor = look.pointSize / 12
                // At a scaled size the view's own units shrink, so the padding is given in them.
                let candidate = WindowMetrics.Notes.Look(
                    padding: CGSize(width: look.padding.width / factor, height: look.padding.height / factor),
                    barLayout: look.barLayout)
                let window = BookWindow(
                    book: book, store: store, preferences: preferences, formatting: formatting,
                    mode: .constant(.page)
                )
                .environment(\.notesLook, candidate)
                let renders = try await Self.render(window) { window in
                    let notes = try #require(
                        subviewTree(of: window.contentView).compactMap { $0 as? SceneTextView }
                            .first { !($0 is ManuscriptTextView) })
                    Self.scale(notes, by: factor)
                    Self.space(notes, by: look.paragraphSpacing)
                    #expect(window.makeFirstResponder(notes))
                    notes.setSelectedRange(NSRange(location: 0, length: 0))
                }
                #expect(formatting.active?.part == .notes, "precondition: the compact bar is active")
                try Self.write(
                    renders, name: look.name, caption: look.caption, to: output, beside: Self.notesMockup)
                try Self.png(Self.panelCloseUp(renders.double)).write(
                    to: output.appending(path: "\(look.name)-close-up@2x.png"))
            }
        }
    }

    /// Shows the 12 pt notes magnified by `factor`, as if set at another size.
    private static func scale(_ notes: NSTextView, by factor: CGFloat) {
        guard factor != 1 else { return }
        notes.scaleUnitSquare(to: NSSize(width: factor, height: factor))
        notes.needsLayout = true
        notes.needsDisplay = true
    }

    /// Shows the notes' paragraphs `spacing` apart. Display only: the model has no spacing, so
    /// the editor finds nothing to save.
    private static func space(_ notes: NSTextView, by spacing: CGFloat) {
        guard spacing > 0, let storage = notes.textStorage else { return }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        storage.addAttribute(
            .paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
    }

    /// The right panel's top and the desk beside it, cut from a 2× render.
    private static func panelCloseUp(_ rep: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let image = try #require(rep.cgImage)
        let width = WindowMetrics.panelWidth + 330
        let crop = CGRect(x: (windowSize.width - width) * 2, y: 0, width: width * 2, height: 330 * 2)
        return NSBitmapImageRep(cgImage: try #require(image.cropping(to: crop)))
    }
}
