import AppKit
import SceneItCore
import SwiftUI

/// The page on its desk (PLAN §4.3): an `NSScrollView` whose document is the scene's
/// `ManuscriptTextView`. The scroll view holds the find bar (Cmd+F) above the desk.
struct PageView: NSViewRepresentable {
    let book: AppOpenBook
    let scene: SceneID
    /// The scene's body. The page reads the model itself; this is here so that SwiftUI updates
    /// the page whenever the body changes.
    let paragraphs: [Paragraph]
    let focus: PageFocus

    func makeCoordinator() -> PageEditor {
        PageEditor(book: book, focus: focus)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(WindowMetrics.deskColor)
        scrollView.findBarPosition = .aboveContent
        let page = ManuscriptTextView.page()
        page.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = page
        context.coordinator.attach(page)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let editable = book.isEditable && context.environment.isEnabled
        context.coordinator.show(scene, editable ? .editable : .readOnly)
    }
}

/// Moves the keyboard focus between the scene's title field and its page (decision 0015).
final class PageFocus {
    weak var title: NSTextField?
    weak var body: NSTextView?

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
