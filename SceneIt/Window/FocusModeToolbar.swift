import AppKit
import SceneItCore
import SwiftUI

/// Hides the window's toolbar in focus mode, and shows it again after, on AppKit's toolbar
/// itself: in the app's `Window` scene, `.toolbarVisibility(.hidden, for: .windowToolbar)` left
/// the toolbar showing (`FocusModeAppWindowTests`).
///
/// It watches the toolbar's `isVisible`, so a toolbar shown again while focus mode is on (by
/// SwiftUI, or a new one) is hidden in the same turn, before anything is drawn. Whether the
/// toolbar showed is decided once, as focus mode begins, so leaving it never shows a toolbar the
/// writer hid (View → Hide Toolbar, which focus mode disables). Taken away (Close Book), it shows
/// the toolbar again.
struct FocusModeToolbar: NSViewRepresentable {
    let chrome: WindowChrome

    func makeCoordinator() -> Coordinator {
        Coordinator(chrome: chrome)
    }

    func makeNSView(context: Context) -> WindowWatcher {
        let view = WindowWatcher()
        let coordinator = context.coordinator
        view.moved = { [weak coordinator] window in coordinator?.watch(window) }
        chrome.toggleToolbar = { [weak coordinator] in coordinator?.toggle() }
        return view
    }

    func updateNSView(_ view: WindowWatcher, context: Context) {
        context.coordinator.apply(chrome.focusMode)
    }

    static func dismantleNSView(_ view: WindowWatcher, coordinator: Coordinator) {
        coordinator.apply(.off)
        coordinator.stopWatching()
    }

    /// Says when it moves to a window.
    class WindowWatcher: NSView {
        var moved: (NSWindow?) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moved(window)
        }
    }

    final class Coordinator {
        private weak var chrome: WindowChrome?
        private weak var window: NSWindow?
        private var watching: [NSKeyValueObservation] = []
        private var focusMode = FocusMode.off
        /// While focus mode is on: whether the toolbar showed as it began.
        private var showedBefore: ToolbarVisibility?

        init(chrome: WindowChrome) {
            self.chrome = chrome
        }

        func watch(_ window: NSWindow?) {
            guard let window, window !== self.window else { return }
            stopWatching()
            self.window = window
            watching = [
                window.observe(\.toolbar, options: [.initial]) { [weak self] window, _ in
                    MainActor.assumeIsolated { self?.watchToolbar(of: window) }
                }
            ]
        }

        func stopWatching() {
            for observation in watching { observation.invalidate() }
            watching = []
        }

        private func watchToolbar(of window: NSWindow) {
            watching = Array(watching.prefix(1))
            if let toolbar = window.toolbar {
                watching.append(
                    toolbar.observe(\.isVisible, options: [.initial]) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.enforce() }
                    })
            }
            enforce()
        }

        func apply(_ mode: FocusMode) {
            guard mode != focusMode else { return }
            focusMode = mode
            switch mode {
            case .on:
                showedBefore = window?.toolbar?.isVisible == false ? .hidden : .shown
            case .off:
                if showedBefore == .shown { window?.toolbar?.isVisible = true }
                showedBefore = nil
            }
            enforce()
        }

        func toggle() {
            guard focusMode == .off else { return }
            window?.toggleToolbarShown(nil)
        }

        /// Hides a toolbar showing in focus mode, and tells the chrome what shows.
        private func enforce() {
            guard let toolbar = window?.toolbar else { return }
            if focusMode == .on, toolbar.isVisible { toolbar.isVisible = false }
            chrome?.toolbarVisibility = toolbar.isVisible ? .shown : .hidden
        }
    }
}

/// Esc that reaches the window itself: with no view holding the focus (just after a sheet
/// opens, say), the window is the first responder and nothing of ours hears the key. It's
/// put at the end of the window's responder chain, which hands it any key nothing took,
/// so a view that handles Esc never passes the key on, and Esc is never handled twice.
///
/// While the window is key, though, an Esc the window itself gets as a key never goes down
/// the chain: AppKit sends `cancelOperation:` to the key window instead, and SwiftUI's window
/// answers it, doing nothing. So while the window is its own first responder, Esc is taken
/// earlier, as a key equivalent, unless a sheet or a dialog is up: their `EscapeKey`, a key
/// equivalent too, takes it then.
///
/// In File a Copy's dialog it also takes `cancelOperation:`, the command a text field or text
/// view makes of Esc, which goes up the chain unanswered there. Not in the main window: there
/// the page and the notes, and the other views that take Esc, answer it themselves, and an
/// `NSTextView` that finds `cancelOperation:` answered up its chain no longer runs its own Esc.
struct WindowEscapeFallback: NSViewRepresentable {
    let keys: WindowKeys
    var commands = EscapeCommands.keyOnly

    nonisolated enum EscapeCommands: Equatable, Sendable {
        /// Only an Esc key nothing took.
        case keyOnly
        /// That, and a `cancelOperation:` nothing answered.
        case keyAndCancelOperation
    }

    func makeNSView(context: Context) -> EscapeView {
        let view = EscapeView()
        let responder = context.coordinator
        view.responder = responder
        view.moved = { [weak responder] window in responder?.insert(after: window) }
        return view
    }

    func makeCoordinator() -> EscapeResponder {
        EscapeResponder(keys: keys, commands: commands)
    }

    func updateNSView(_ view: EscapeView, context: Context) {}

    static func dismantleNSView(_ view: EscapeView, coordinator: EscapeResponder) {
        coordinator.remove()
    }

    /// Takes an Esc as a key equivalent while no view in its window has the focus.
    final class EscapeView: FocusModeToolbar.WindowWatcher {
        weak var responder: EscapeResponder?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let window, window.firstResponder === window, let responder else { return false }
            return responder.escape(event, offered: .asKeyEquivalent) == .handled
        }
    }

    final class EscapeResponder: NSResponder {
        private weak var keys: WindowKeys?
        private weak var window: NSWindow?
        nonisolated private let commands: EscapeCommands

        init(keys: WindowKeys, commands: EscapeCommands) {
            self.keys = keys
            self.commands = commands
            super.init()
        }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            if selector == #selector(cancelOperation(_:)) { return commands == .keyAndCancelOperation }
            return super.responds(to: selector)
        }

        override func cancelOperation(_ sender: Any?) {
            keys?.escape(from: .window)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("not loaded from a nib")
        }

        /// At the end of the window's chain, so SwiftUI's own responders after the window stay
        /// where SwiftUI put them.
        func insert(after window: NSWindow?) {
            // Out of a window, out of its chain: the chain doesn't keep its responders alive.
            guard let window else { return remove() }
            guard self.window !== window else { return }
            remove()
            var last: NSResponder = window
            while let next = last.nextResponder, next !== self { last = next }
            nextResponder = nil
            last.nextResponder = self
            self.window = window
        }

        func remove() {
            guard let window else { return }
            var responder: NSResponder = window
            while let next = responder.nextResponder {
                if next === self {
                    responder.nextResponder = nextResponder
                    break
                }
                responder = next
            }
            self.window = nil
        }

        enum Offer {
            case asKey, asKeyEquivalent
        }

        /// As a key equivalent, the Esc is left to a sheet's or a dialog's own `EscapeKey`, which
        /// is offered it too, and may close something inside the layer first.
        func escape(_ event: NSEvent, offered offer: Offer) -> KeyOutcome {
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            guard event.keyCode == 53, plain, let keys else { return .passedOn }
            if offer == .asKeyEquivalent, EscapeLayer.keyEquivalentTaker(in: keys.escapeContext) == .layer {
                return .passedOn
            }
            return keys.escape(from: .window)
        }

        override func keyDown(with event: NSEvent) {
            if escape(event, offered: .asKey) == .handled { return }
            super.keyDown(with: event)
        }
    }
}

/// Tells `moved` the window it's in, and when it leaves it.
struct WindowReporter: NSViewRepresentable {
    let moved: (NSWindow?) -> Void

    func makeNSView(context: Context) -> FocusModeToolbar.WindowWatcher {
        let view = FocusModeToolbar.WindowWatcher()
        view.moved = moved
        return view
    }

    func updateNSView(_ view: FocusModeToolbar.WindowWatcher, context: Context) {}
}
