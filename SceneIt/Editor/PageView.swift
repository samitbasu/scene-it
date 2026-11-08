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
    /// The scene's body and comments. The page reads the model itself; these are here so that
    /// SwiftUI updates the page whenever they change, its text or its underlines.
    let paragraphs: [Paragraph]
    let comments: [Comment]

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
    @discardableResult
    func focusBody() -> Bool {
        guard let body, let window = body.window else { return false }
        return window.makeFirstResponder(body)
    }

    /// Whether the page has the focus: its title, its body, or its find bar's field.
    var holdsFocus: Bool {
        guard let window = body?.window ?? title?.window else { return false }
        switch window.firstResponder {
        case let editor as NSTextView where editor.isFieldEditor:
            guard let field = editor.delegate as? NSTextField else { return false }
            return field === title || field === desk?.findField
        case let responder: return responder != nil && responder === body
        }
    }

    /// The view with the window's focus: a field's own view while its field editor has it.
    var focusedView: NSView? {
        switch body?.window?.firstResponder {
        case let editor as NSTextView where editor.isFieldEditor: editor.delegate as? NSView
        case let view as NSView: view
        default: nil
        }
    }

    /// Hides the body's find bar, as its Done button does, which hands the body the focus. The
    /// focus goes back to `focused` instead if that's elsewhere, and to the body if it was the
    /// find bar's field, so it's never left with the window, where no Esc is heard.
    func closeFindBar(keepingFocus focused: NSView?) {
        let field = desk?.findField
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.hideFindInterface.rawValue
        body?.performFindPanelAction(item)
        if let focused, focused !== field, focused !== body, let window = focused.window {
            window.makeFirstResponder(focused)
        } else if !holdsFocus {
            focusBody()
        }
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

    /// What the title field selects when it next shows the scene: a search result being opened
    /// (PLAN §9.1).
    var titleSelection = PendingSelection()
}
