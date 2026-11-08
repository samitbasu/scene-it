import SceneItCore
import SwiftUI

/// One window's focus mode (PLAN §4.6), with the rules and look it follows. It lives as long as
/// the window over one open book, so a book opens out of focus mode, and closing it ends focus
/// mode.
@MainActor
@Observable
final class WindowChrome {
    private(set) var focusMode = FocusMode.off
    /// How many times focus mode has begun: the hint shows afresh each time.
    private(set) var entries = 0
    let rules: FocusModeRules
    let look: FocusModeLook

    init(rules: FocusModeRules = .recommended, look: FocusModeLook = .recommended) {
        self.rules = rules
        self.look = look
    }

    func shows(_ part: ChromePart) -> Bool {
        focusMode.shows(part, under: rules)
    }

    func set(_ mode: FocusMode) {
        guard mode != focusMode else { return }
        focusMode = mode
        if mode == .on { entries += 1 }
    }

    func toggle() {
        set(focusMode.toggled)
    }

    func note(_ event: FocusModeEvent) {
        set(focusMode.after(event, under: rules))
    }
}

/// How focus mode looks: the owner's pick from #21's candidates.
struct FocusModeLook: Hashable {
    var desk: FocusDesk
    var exit: FocusExitCue

    static let recommended = FocusModeLook(desk: .unchanged, exit: .fadingHint)
}

/// The desk around the page in focus mode.
enum FocusDesk: Hashable, CaseIterable {
    case unchanged
    /// Darker, so the page stands out more.
    case dimmed
}

/// What tells the writer how to leave focus mode, besides View → Focus Mode.
enum FocusExitCue: Hashable, CaseIterable {
    case none
    /// "Press Esc to leave focus mode" low on the desk, fading after a few seconds.
    case fadingHint
    /// A faint button in the top corner that leaves focus mode, clearer under the pointer.
    case cornerButton
}

extension WindowMetrics {
    enum Focus {
        static let dimmedDesk = NSColor(red: 0.60, green: 0.60, blue: 0.58, alpha: 1)
        static let hintShown = Interval.seconds(3)
        static let hintFade = Interval(clamping: .milliseconds(600))
        static let hintInset: CGFloat = 28
        static let cornerInset: CGFloat = 10
        static let cornerRestingOpacity = 0.45
    }
}

/// Shows or hides the window's toolbar as focus mode says, on AppKit's toolbar itself: SwiftUI's
/// `toolbarVisibility` left a toolbar bridged into an `NSHostingController`'s window showing.
struct WindowToolbarVisibility: NSViewRepresentable {
    let chrome: WindowChrome

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let shown = chrome.shows(.toolbar)
        DispatchQueue.main.async { [weak view] in
            guard let toolbar = view?.window?.toolbar, toolbar.isVisible != shown else { return }
            toolbar.isVisible = shown
        }
    }
}

/// What focus mode shows over the page to say how to leave it (`FocusExitCue`).
struct FocusExitCueView: View {
    let chrome: WindowChrome
    @State private var hintVisible = false
    @State private var hovering = false

    var body: some View {
        if chrome.focusMode == .on {
            switch chrome.look.exit {
            case .none:
                EmptyView()
            case .fadingHint:
                hint
            case .cornerButton:
                corner
            }
        }
    }

    private var hint: some View {
        Text(WindowWording.focusModeHint)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.6)))
            .opacity(hintVisible ? 1 : 0)
            .padding(.bottom, WindowMetrics.Focus.hintInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(!hintVisible)
            .task(id: chrome.entries) {
                hintVisible = true
                try? await Task.sleep(for: WindowMetrics.Focus.hintShown.duration)
                withAnimation(.easeOut(duration: WindowMetrics.Focus.hintFade.timeInterval)) {
                    hintVisible = false
                }
            }
    }

    private var corner: some View {
        Button {
            chrome.set(.off)
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.background.opacity(0.9)))
                .overlay(Circle().strokeBorder(.separator))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : WindowMetrics.Focus.cornerRestingOpacity)
        .onHover { hovering = $0 }
        .help(WindowWording.leaveFocusMode)
        .accessibilityLabel(WindowWording.leaveFocusMode)
        .padding(WindowMetrics.Focus.cornerInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}
