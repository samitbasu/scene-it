import AppKit
import SceneItCore

/// The window's two editors of scene text, the page and the notes, each made once and kept for
/// the window's life, however often SwiftUI rebuilds the views that show them. The window's
/// life is one `OpenBook`'s (`MainWindow` keys it on `OpenBook.instanceID`, ADR 0038), so the
/// editors never outlive the book they edit, even when the same package is opened again. They must outlive those rebuilds: the scenes' undo histories record typing
/// against an editor's own text storage, and an undo replayed on a storage that's gone does
/// nothing, or raises.
final class SceneEditors {
    private let book: AppOpenBook
    private let preferences: AppPreferences
    private let formatting: EditorFormatting
    private let focus: PageFocus
    private weak var keys: WindowKeys?
    /// The selected comment, which the page, the notes and the comments panel share.
    let comments = CommentSelection()

    init(
        book: AppOpenBook, preferences: AppPreferences, formatting: EditorFormatting, focus: PageFocus,
        keys: WindowKeys
    ) {
        self.book = book
        self.preferences = preferences
        self.formatting = formatting
        self.focus = focus
        self.keys = keys
    }

    /// Built when first shown, so that only the window SwiftUI keeps builds one.
    private(set) lazy var page: SceneTextHost<DeskView> = {
        let scrollView = DeskView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(WindowMetrics.deskColor)
        scrollView.findBarPosition = .aboveContent
        let page = ManuscriptTextView.page(editability: { [weak book = self.book] in .page(book) })
        page.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = page
        page.focus = focus
        if case .filedCopy = book.document { page.paper = NSColor(WindowMetrics.filedCopyPaper) }
        page.keys = keys
        scrollView.keys = keys
        focus.body = page
        scrollView.pinched = { [preferences] in preferences.setZoom($0) }
        scrollView.show(preferences.zoom)
        return SceneTextHost(
            SceneTextEditor(
                book: book, part: .body, preferences: preferences, formatting: formatting, comments: comments),
            page,
            in: scrollView)
    }()

    private(set) lazy var notes: SceneTextHost<NotesScrollView> = {
        let scrollView = NotesScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.findBarPosition = .aboveContent
        let notes = SceneTextView(
            editability: { [weak book = self.book] in Editability(book, for: .annotations) })
        notes.configure(.notes)
        notes.drawsBackground = false
        notes.textContainerInset = WindowMetrics.Notes.padding
        notes.setAccessibilityLabel(WindowWording.tab(.notes))
        notes.keys = keys
        scrollView.holdGrowingText(notes)
        return SceneTextHost(
            SceneTextEditor(
                book: book, part: .notes, preferences: preferences, formatting: formatting, comments: comments
            ), notes,
            in: scrollView)
    }()
}

/// One editor of scene text with its views, which a `HostingSlot` shows while SwiftUI shows it.
final class SceneTextHost<Scroll: NSScrollView> {
    let editor: SceneTextEditor
    let textView: SceneTextView
    let scrollView: Scroll

    init(_ editor: SceneTextEditor, _ textView: SceneTextView, in scrollView: Scroll) {
        self.editor = editor
        self.textView = textView
        self.scrollView = scrollView
        editor.attach(textView)
    }

    func mount(in slot: HostingSlot) {
        slot.mount(scrollView)
    }

    /// Takes the views out of `slot` as SwiftUI takes it away, if they're still there (they may
    /// have moved on to another): AppKit would leave the text view, or its find bar's field,
    /// the focus, typing into text no one sees, with its bar active. The focus goes to `next`
    /// if it can take it.
    func unmount(from slot: HostingSlot, handingFocusTo next: NSView?) {
        guard scrollView.superview === slot else { return }
        if let window = textView.window, holdsFocus(window.firstResponder) {
            let handedOn = next.map { $0.window === window && window.makeFirstResponder($0) } ?? false
            if !handedOn { window.makeFirstResponder(nil) }
        }
        textView.leaveKeyboardFocus()
        scrollView.removeFromSuperview()
    }

    /// Whether `responder` is in the scroll view: the text view, or the find bar's field, whose
    /// field editor is the responder while it's being edited.
    private func holdsFocus(_ responder: NSResponder?) -> Bool {
        let view: NSView? =
            switch responder {
            case let editor as NSTextView where editor.isFieldEditor: editor.delegate as? NSView
            case let view as NSView: view
            default: nil
            }
        return view?.isDescendant(of: scrollView) ?? false
    }
}

/// Where SwiftUI shows a host's scroll view. SwiftUI makes and dismantles slots as it likes;
/// the host's views move between them.
final class HostingSlot: NSView {
    func mount(_ view: NSView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }
}
