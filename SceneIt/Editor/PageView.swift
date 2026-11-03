import AppKit
import SceneItCore
import SwiftUI

/// The page on its desk (PLAN §4.3): a `DeskView` whose document is the scene's
/// `ManuscriptTextView`, at the writer's zoom. The desk holds the find bar (Cmd+F) above it.
struct PageView: NSViewRepresentable {
    let book: AppOpenBook
    let preferences: AppPreferences
    let scene: SceneID
    /// The scene's body. The page reads the model itself; this is here so that SwiftUI updates
    /// the page whenever the body changes.
    let paragraphs: [Paragraph]
    let focus: PageFocus
    let formatting: PageFormatting

    func makeCoordinator() -> PageEditor {
        PageEditor(book: book, focus: focus, formatting: formatting)
    }

    func makeNSView(context: Context) -> DeskView {
        let scrollView = DeskView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(WindowMetrics.deskColor)
        scrollView.findBarPosition = .aboveContent
        let page = ManuscriptTextView.page()
        page.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = page
        context.coordinator.attach(page)
        scrollView.pinched = { [preferences] in preferences.setZoom($0) }
        scrollView.show(preferences.zoom)
        return scrollView
    }

    func updateNSView(_ scrollView: DeskView, context: Context) {
        let editable = book.isEditable && context.environment.isEnabled
        context.coordinator.show(scene, editable ? .editable : .readOnly)
        scrollView.show(preferences.zoom)
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
}
