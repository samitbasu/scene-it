import AppKit
import SceneItCore
import SwiftUI

/// The open scene's notes (PLAN §8.2), in the Notes tab: a `SceneTextView` the panel's width,
/// single-spaced, scrolling once the notes outgrow the panel. The same `SceneTextEditor` as the
/// page's keeps it in step with the model, for `scene.notes`.
struct NotesView: NSViewRepresentable {
    let book: AppOpenBook
    let scene: SceneID
    /// The scene's notes. The view reads the model itself; this is here so that SwiftUI updates
    /// the view whenever the notes change.
    let notes: [Paragraph]
    let formatting: EditorFormatting

    func makeCoordinator() -> SceneTextEditor {
        SceneTextEditor(book: book, part: .notes, formatting: formatting)
    }

    func makeNSView(context: Context) -> NotesScrollView {
        let scrollView = NotesScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.findBarPosition = .aboveContent
        let notes = SceneTextView(usingTextLayoutManager: true)
        notes.configure(.notes)
        notes.drawsBackground = false
        notes.textContainerInset = NSSize(
            width: WindowMetrics.Notes.padding.width, height: WindowMetrics.Notes.padding.height)
        notes.textContainer?.widthTracksTextView = true
        notes.isVerticallyResizable = true
        notes.isHorizontallyResizable = false
        notes.autoresizingMask = [.width]
        notes.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        notes.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        notes.setAccessibilityLabel(WindowWording.tab(.notes))
        scrollView.documentView = notes
        context.coordinator.attach(notes)
        return scrollView
    }

    func updateNSView(_ scrollView: NotesScrollView, context: Context) {
        context.coordinator.show(scene, .init(book, in: context.environment))
    }

    static func dismantleNSView(_ view: NotesScrollView, coordinator: SceneTextEditor) {
        coordinator.detach()
    }
}

/// Keeps the notes at least as tall as the panel, so a click anywhere below the last line
/// reaches them.
final class NotesScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let notes = documentView as? NSTextView else { return }
        let height = contentSize.height
        if notes.minSize.height != height {
            notes.minSize = NSSize(width: 0, height: height)
            notes.sizeToFit()
        }
    }
}
