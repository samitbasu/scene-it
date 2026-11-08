import AppKit
import SceneItCore
import SwiftUI

/// Where the window's Undo and Redo go (PLAN §8.6): the undo manager `UndoStack` picks for the
/// window's mode and focus. The toolbar's buttons and the Edit menu's items both call it, and
/// show its state: whether there's anything to undo or redo, and what.
@MainActor
@Observable
final class UndoRouter {
    @ObservationIgnored let book: AppOpenBook
    var mode = WindowMode.page {
        didSet { refresh() }
    }
    private(set) var state = UndoState.nothing

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var windowObserver: (any NSObjectProtocol)?
    @ObservationIgnored private weak var observed: UndoManager?
    @ObservationIgnored private var managerObservers: [any NSObjectProtocol] = []

    init(book: AppOpenBook) {
        self.book = book
    }

    isolated deinit {
        stopObserving()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    /// The window whose focus decides. After every event it handles (a click or key that may
    /// move the focus), the router looks again.
    func attach(to window: NSWindow?) {
        guard window !== self.window else { return }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        self.window = window
        if let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    /// The window whose first responder decides: a dialog attached to the window, while there
    /// is one, since the window behind it keeps its first responder (the page, say).
    private var focusedWindow: NSWindow? {
        window?.attachedSheet ?? window
    }

    var stack: UndoStack {
        UndoStack(
            mode: mode, focus: Self.focus(of: focusedWindow?.firstResponder),
            dialog: window?.attachedSheet == nil ? .none : .attached)
    }

    /// The undo manager Undo and Redo act on now, if any.
    var manager: UndoManager? {
        switch stack {
        case .focusedText: focusedWindow?.firstResponder?.undoManager
        case .structure: book.structureUndo
        case .errors: book.errorsUndo
        case .none: nil
        }
    }

    func undo() {
        guard book.isEditable, let manager, manager.canUndo else { return }
        manager.undo()
        refresh()
    }

    func redo() {
        guard book.isEditable, let manager, manager.canRedo else { return }
        manager.redo()
        refresh()
    }

    private static func focus(of responder: NSResponder?) -> UndoFocus {
        switch responder {
        case let view as UndoFocusView: view.focus
        case is NSText: .text
        default: .elsewhere
        }
    }

    /// A read-only book, or one whose edits are refused while it's written elsewhere, has
    /// nothing to undo: an undo there would change what the book can't keep.
    private func refresh() {
        let current = manager
        if current !== observed { observe(current) }
        let new = book.isEditable ? UndoState(current) : .nothing
        if new != state { state = new }
    }

    /// Listens to the routed manager only, synchronously, so the state is right as soon as it
    /// changes, without waiting for the next event.
    private func observe(_ manager: UndoManager?) {
        stopObserving()
        observed = manager
        guard let manager else { return }
        managerObservers = [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
            .NSUndoManagerCheckpoint,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: manager, queue: nil) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func stopObserving() {
        for observer in managerObservers { NotificationCenter.default.removeObserver(observer) }
        managerObservers = []
        observed = nil
    }
}

/// What Undo and Redo show.
struct UndoState: Equatable {
    /// "Undo Typing", while there's something to undo.
    var undo: String?
    var redo: String?

    static let nothing = UndoState(undo: nil, redo: nil)

    init(undo: String?, redo: String?) {
        self.undo = undo
        self.redo = redo
    }

    init(_ manager: UndoManager?) {
        guard let manager, !manager.isUndoing, !manager.isRedoing else {
            self = .nothing
            return
        }
        undo = manager.canUndo ? manager.undoMenuItemTitle : nil
        redo = manager.canRedo ? manager.redoMenuItemTitle : nil
    }
}

/// Edit → Undo and Redo (PLAN §11), for the focused window's router.
struct UndoCommands: Commands {
    @FocusedValue(\.undoRouter) private var router

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(router?.state.undo ?? WindowWording.undo) { router?.undo() }
                .keyboardShortcut("z")
                .disabled(router?.state.undo == nil)
            Button(router?.state.redo ?? WindowWording.redo) { router?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(router?.state.redo == nil)
        }
    }
}

extension FocusedValues {
    @Entry var undoRouter: UndoRouter?
}

/// A view that takes the keyboard focus where there's no text to type in: a sheet, or the
/// Errors tab after the writer acts in it. Its undo manager is the router's, so anything in
/// AppKit that asks the focused view for one gets what Undo acts on.
final class UndoFocusView: NSView {
    /// Where the view sits, which decides how it takes and shows the focus.
    enum Role {
        /// A rail sheet: it takes the focus as it opens, from the page or panel it covers.
        case sheet
        /// The Errors tab: it takes the focus when the writer acts in it, and shows a ring
        /// while it has it, so the writer can see that typing won't reach the page.
        case errorsTab
    }

    weak var router: UndoRouter?
    var role = Role.sheet {
        didSet { needsDisplay = true }
    }
    /// Esc gives the focus back to where the writer was typing, when the window has nothing
    /// for Esc to close.
    var escape: () -> Void = {}
    weak var keys: WindowKeys?

    var focus: UndoFocus {
        switch role {
        case .sheet: .elsewhere
        case .errorsTab: .errorsTab
        }
    }

    var showsFocusRing: Bool {
        role == .errorsTab
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if role == .sheet { takeFocus() }
    }

    override var undoManager: UndoManager? {
        router?.manager
    }

    func takeFocus() {
        window?.makeFirstResponder(self)
    }

    var hasFocus: Bool {
        window?.firstResponder === self
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func cancelOperation(_ sender: Any?) {
        if keys?.escape() != .handled { escape() }
    }

    /// The Errors tab is a Tab stop. A sheet's holder handles no Tab, so nothing the sheet covers
    /// can take the focus from it.
    override func doCommand(by selector: Selector) {
        switch (role, selector) {
        case (.errorsTab, #selector(NSResponder.insertTab(_:))): keys?.tab(.forward, from: .panel)
        case (.errorsTab, #selector(NSResponder.insertBacktab(_:))): keys?.tab(.backward, from: .panel)
        default: super.doCommand(by: selector)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsFocusRing, hasFocus else { return }
        let ring = NSBezierPath(
            roundedRect: bounds.insetBy(dx: WindowMetrics.focusRingWidth, dy: WindowMetrics.focusRingWidth),
            xRadius: WindowMetrics.focusRingRadius, yRadius: WindowMetrics.focusRingRadius)
        ring.lineWidth = WindowMetrics.focusRingWidth
        NSColor.keyboardFocusIndicatorColor.setStroke()
        ring.stroke()
    }
}

/// Puts an `UndoFocusView` behind its content. `anchor` lets the content give it the focus.
struct UndoFocusHolder: NSViewRepresentable {
    let role: UndoFocusView.Role
    var anchor: UndoFocusAnchor?
    var escape: () -> Void = {}
    @Environment(UndoRouter.self) private var router: UndoRouter?
    @Environment(\.windowKeys) private var keys

    func makeNSView(context: Context) -> UndoFocusView {
        let view = UndoFocusView()
        view.role = role
        return view
    }

    func updateNSView(_ view: UndoFocusView, context: Context) {
        view.router = router
        view.role = role
        view.escape = escape
        view.keys = keys
        anchor?.view = view
    }
}

/// Lets a SwiftUI view hand the focus to its `UndoFocusHolder`.
final class UndoFocusAnchor {
    weak var view: UndoFocusView?

    func takeFocus() {
        view?.takeFocus()
    }
}

/// Tells the router which window it serves.
struct UndoRouterWindow: NSViewRepresentable {
    let router: UndoRouter

    func makeNSView(context: Context) -> WindowView {
        WindowView()
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.router = router
        router.attach(to: view.window)
    }

    final class WindowView: NSView {
        weak var router: UndoRouter?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            router?.attach(to: window)
        }
    }
}
