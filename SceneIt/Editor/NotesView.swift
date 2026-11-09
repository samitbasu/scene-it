import AppKit
import SceneItCore
import SwiftUI

/// The open scene's notes (PLAN §8.2), in the Notes tab: the window's notes `SceneTextView`,
/// the panel's width, single-spaced, scrolling once the notes outgrow the panel. A
/// `SceneTextEditor` like the page's keeps it in step with the model, for `scene.notes`.
struct NotesView: NSViewRepresentable {
    let book: AppOpenBook
    let editors: SceneEditors
    let scene: SceneID
    /// The scene's notes. The view reads the model itself; this is here so that SwiftUI updates
    /// the view whenever the notes change.
    let notes: [Paragraph]

    func makeCoordinator() -> SceneEditors {
        editors
    }

    func makeNSView(context: Context) -> HostingSlot {
        let slot = HostingSlot()
        editors.notes.mount(in: slot)
        return slot
    }

    func updateNSView(_ slot: HostingSlot, context: Context) {
        let notes = editors.notes
        notes.mount(in: slot)
        notes.editor.show(scene, .init(book, for: .annotations, in: context.environment))
    }

    /// The focus goes back to the page, where the writer can go on typing, when the notes leave
    /// with their tab.
    static func dismantleNSView(_ slot: HostingSlot, coordinator editors: SceneEditors) {
        editors.notes.unmount(from: slot, handingFocusTo: editors.page.textView)
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
