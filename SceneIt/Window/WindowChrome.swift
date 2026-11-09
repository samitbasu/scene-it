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
    /// Whether the window's toolbar shows, as AppKit has it (`FocusModeToolbar` keeps it), for
    /// View → Show/Hide Toolbar.
    var toolbarVisibility = ToolbarVisibility.shown
    /// Shows or hides the window's toolbar, as View → Show/Hide Toolbar does.
    @ObservationIgnored var toggleToolbar: () -> Void = {}

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

/// The main window's `WindowChrome` and mode while a book is open in it, for the View menu.
/// There's one main window (ADR 0038), so the menu acts on it as on the book's preferences,
/// whichever window is key.
@MainActor
@Observable
final class MainWindowChrome {
    private(set) var chrome: WindowChrome?
    /// What the window shows over the book: the page or a sheet.
    private(set) var mode: Binding<WindowMode>?

    func show(_ chrome: WindowChrome, mode: Binding<WindowMode>) {
        self.chrome = chrome
        self.mode = mode
    }

    func gone(_ chrome: WindowChrome) {
        guard self.chrome === chrome else { return }
        self.chrome = nil
        mode = nil
    }
}

enum ToolbarVisibility {
    case shown, hidden
}

extension WindowMetrics {
    enum Focus {
        static let hintShown = Interval.seconds(3)
        static let hintFade = Interval(clamping: .milliseconds(600))
        static let hintInset: CGFloat = 28
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
