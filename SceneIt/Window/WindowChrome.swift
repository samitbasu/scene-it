import SceneItCore
import SwiftUI

/// One window's focus mode (PLAN §4.6). It lives as long as the window over one open book, so a
/// book opens out of focus mode, and closing it ends focus mode.
@MainActor
@Observable
final class WindowChrome {
    private(set) var focusMode = FocusMode.off
    /// How many times focus mode has begun: the hint shows afresh each time.
    private(set) var entries = 0

    func shows(_ part: ChromePart) -> Bool {
        focusMode.shows(part)
    }

    func set(_ mode: FocusMode) {
        guard mode != focusMode else { return }
        focusMode = mode
        if mode == .on { entries += 1 }
    }

    func toggle() {
        set(focusMode.toggled)
    }
}

extension WindowMetrics {
    enum Focus {
        static let hintShown = Interval.seconds(3)
        static let hintFade = Interval(clamping: .milliseconds(600))
        static let hintInset: CGFloat = 28
    }
}

/// Hides the window's toolbar in focus mode, and shows it again after, on AppKit's toolbar
/// itself: in the app's `Window` scene, `.toolbarVisibility(.hidden, for: .windowToolbar)` left
/// the toolbar showing (`FocusModeAppWindowTests`). Only a toolbar focus mode hid is shown
/// again, so one the writer hid (View → Hide Toolbar) stays hidden, and a book closed in focus
/// mode gives the window its toolbar back.
struct FocusModeToolbar: NSViewRepresentable {
    let chrome: WindowChrome

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let shown = chrome.shows(.toolbar)
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            coordinator.show(shown, in: view?.window)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.show(true, in: view.window)
    }

    final class Coordinator {
        /// While focus mode is on: the window, and whether its toolbar showed as focus mode
        /// began, which is decided once.
        private var hiding: (window: Weak<NSWindow>, wasShowing: Bool)?

        func show(_ shown: Bool, in window: NSWindow?) {
            if shown {
                if let hiding, hiding.wasShowing { hiding.window.value?.toolbar?.isVisible = true }
                hiding = nil
                return
            }
            guard let window = window ?? hiding?.window.value else { return }
            if hiding == nil { hiding = (Weak(window), window.toolbar?.isVisible == true) }
            // Every update, so a toolbar SwiftUI shows again (or makes anew) is hidden again.
            if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
        }
    }

    struct Weak<T: AnyObject> {
        weak var value: T?

        init(_ value: T) {
            self.value = value
        }
    }
}

/// "Press Esc to leave focus mode", low on the desk as focus mode begins, fading after a few
/// seconds (the owner's pick, #21).
struct FocusModeHint: View {
    let chrome: WindowChrome
    @State private var visible = false

    var body: some View {
        if chrome.focusMode == .on {
            Text(WindowWording.focusModeHint)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.6)))
                .opacity(visible ? 1 : 0)
                .padding(.bottom, WindowMetrics.Focus.hintInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(!visible)
                .task(id: chrome.entries) {
                    visible = true
                    try? await Task.sleep(for: WindowMetrics.Focus.hintShown.duration)
                    withAnimation(.easeOut(duration: WindowMetrics.Focus.hintFade.timeInterval)) {
                        visible = false
                    }
                }
        }
    }
}
