import AppKit
import SceneItCore
import SwiftUI

/// The page on its desk (PLAN §4.3): the window's `DeskView`, whose document is its
/// `ManuscriptTextView`, at the writer's zoom. The desk holds the find bar (Cmd+F) above it.
struct PageView: NSViewRepresentable {
    let book: AppOpenBook
    let preferences: AppPreferences
    let editors: SceneEditors
    let scene: SceneID
    /// The scene's body. The page reads the model itself; this is here so that SwiftUI updates
    /// the page whenever the body changes.
    let paragraphs: [Paragraph]

    func makeCoordinator() -> SceneEditors {
        editors
    }

    func makeNSView(context: Context) -> HostingSlot {
        let slot = HostingSlot()
        editors.page.mount(in: slot)
        return slot
    }

    func updateNSView(_ slot: HostingSlot, context: Context) {
        let page = editors.page
        page.mount(in: slot)
        page.editor.show(scene, .init(book, in: context.environment))
        page.scrollView.show(preferences.zoom)
    }

    static func dismantleNSView(_ slot: HostingSlot, coordinator editors: SceneEditors) {
        editors.page.unmount(from: slot, handingFocusTo: nil)
    }
}

/// Moves the keyboard focus between the scene's title field and its page (decision 0015).
final class PageFocus {
    weak var title: NSTextField?
    weak var body: NSTextView?

    var desk: DeskView? {
        body?.enclosingScrollView as? DeskView
    }

    /// Gives the body the focus, with its selection as it was.
    func focusBody() {
        guard let body, let window = body.window else { return }
        window.makeFirstResponder(body)
    }

    /// Puts the caret at the start of the body.
    func focusBodyStart() {
        guard let body, body.isEditable, let window = body.window, window.makeFirstResponder(body) else {
            return
        }
        body.setSelectedRange(NSRange(location: 0, length: 0))
        body.scrollRangeToVisible(body.selectedRange())
    }

    func focusTitle() {
        guard let title, title.isEnabled else { return }
        title.window?.makeFirstResponder(title)
    }

    private var pendingTitleSelection: NSRange?

    /// Selects `range` of the title, with the focus, the next time the title field is updated
    /// outside a sheet: a search result being opened (PLAN §9.1).
    func selectTitle(_ range: NSRange) {
        pendingTitleSelection = range
    }

    /// The pending title selection, once.
    func takeTitleSelection() -> NSRange? {
        defer { pendingTitleSelection = nil }
        return pendingTitleSelection
    }
}
