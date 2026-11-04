import AppKit
import SceneItCore

/// The window's two editors of scene text, the page and the notes, each made once and kept for
/// the window's life, which is its book's (ADR 0021), however often SwiftUI rebuilds the views
/// that show them. They must outlive those rebuilds: the scenes' undo histories record typing
/// against an editor's own text storage, and an undo replayed on a storage that's gone does
/// nothing, or raises.
final class SceneEditors {
    private let book: AppOpenBook
    private let preferences: AppPreferences
    private let formatting: EditorFormatting
    private let focus: PageFocus

    init(book: AppOpenBook, preferences: AppPreferences, formatting: EditorFormatting, focus: PageFocus) {
        self.book = book
        self.preferences = preferences
        self.formatting = formatting
        self.focus = focus
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
        let page = ManuscriptTextView.page()
        page.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = page
        page.focus = focus
        focus.body = page
        scrollView.pinched = { [preferences] in preferences.setZoom($0) }
        scrollView.show(preferences.zoom)
        return SceneTextHost(
            SceneTextEditor(book: book, part: .body, formatting: formatting), page, in: scrollView)
    }()

    private(set) lazy var notes: SceneTextHost<NotesScrollView> = {
        let scrollView = NotesScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.findBarPosition = .aboveContent
        let notes = SceneTextView(usingTextLayoutManager: true)
        notes.configure(.notes)
        notes.drawsBackground = false
        notes.textContainer?.widthTracksTextView = true
        notes.isVerticallyResizable = true
        notes.isHorizontallyResizable = false
        notes.autoresizingMask = [.width]
        notes.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        notes.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        notes.setAccessibilityLabel(WindowWording.tab(.notes))
        scrollView.documentView = notes
        return SceneTextHost(
            SceneTextEditor(book: book, part: .notes, formatting: formatting), notes, in: scrollView)
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

    /// Takes the views out of the window, as SwiftUI takes their slot away: AppKit would leave
    /// the text view the focus, typing into text no one sees, with its bar active. The focus
    /// goes to `next` if it can take it.
    func unmount(handingFocusTo next: NSView?) {
        if let window = textView.window, window.firstResponder === textView {
            let handedOn = next.map { $0.window === window && window.makeFirstResponder($0) } ?? false
            if !handedOn { window.makeFirstResponder(nil) }
        }
        editor.keyboardFocusChanged(.elsewhere)
        scrollView.removeFromSuperview()
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
