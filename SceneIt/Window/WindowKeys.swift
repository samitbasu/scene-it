import AppKit
import SceneItCore
import SwiftUI

/// One window's Esc and Tab (PLAN §8.4). `escape()` closes what `EscapeLayer` says, and
/// `tab(_:from:)` tries the stops in `TabStop`'s order, so each order is in one place.
///
/// Every Esc in the window asks `escape()` first: the page, the notes and the title; comment
/// cards, Comments' search field and the Errors tab; the page's find bar field; and `EscapeKey`
/// in the sheets, File a Copy's dialog and the palettes. The one exception is the notes' own find
/// bar, whose Esc stays AppKit's: it closes that bar.
@MainActor
@Observable
final class WindowKeys {
    /// The palette open in a formatting bar, if one is. Its control clears it when it goes, so
    /// a palette whose bar is hidden can't hold Esc.
    var popover: WindowPopover?
    @ObservationIgnored let chrome: WindowChrome
    @ObservationIgnored let filing: FilingFlow
    @ObservationIgnored private let page: PageFocus
    @ObservationIgnored let mode: Binding<WindowMode>
    /// The right panel's tab while the panel shows; `nil` while it's collapsed or hidden.
    @ObservationIgnored var shownPanelTab: RightPanelTab?
    /// How each tab takes the focus: its editor, or its first control. `true` only if it did.
    @ObservationIgnored private var panelFocus: [RightPanelTab: () -> Bool] = [:]

    init(chrome: WindowChrome, filing: FilingFlow, page: PageFocus, mode: Binding<WindowMode>) {
        self.chrome = chrome
        self.filing = filing
        self.page = page
        self.mode = mode
    }

    var escapeContext: EscapeContext {
        EscapeContext(
            popover: popover == nil ? .absent : .present, dialog: filing.draft == nil ? nil : filing.stage,
            mode: mode.wrappedValue, findBar: page.desk?.findField == nil ? .absent : .present,
            focusMode: chrome.focusMode)
    }

    /// Closes what Esc closes now, or says there's nothing, so the focused view's own Esc applies.
    /// `focus` is where the focus was when the key came, if that was recorded earlier.
    @discardableResult
    func escape(restoring focus: PageFocus.Focus? = nil) -> EscapeOutcome {
        switch EscapeLayer.escape(in: escapeContext) {
        case .passOn:
            return .passedOn
        case .hold:
            NSSound.beep()
        case .close(.popover):
            popover = nil
        case .close(.dialog):
            filing.cancel()
        case .close(.sheet):
            mode.wrappedValue = mode.wrappedValue.closingSheet
        case .close(.findBar):
            page.closeFindBar(restoring: focus)
        case .close(.focusMode):
            chrome.set(.off)
        }
        return .handled
    }

    /// `escape()` for a SwiftUI field, which is still handling the key: what Esc closes is decided
    /// now, and closed on the next turn. Moving the focus while the field handles its key (as
    /// closing the find bar does) loses what was typed in it.
    func escapeAfterThisKey() -> EscapeOutcome {
        if EscapeLayer.escape(in: escapeContext) == .passOn { return .passedOn }
        let focus = page.currentFocus
        DispatchQueue.main.async { [weak self] in self?.escape(restoring: focus) }
        return .handled
    }

    /// Moves the focus to the next stop after `stop` that takes it. `false` if none does, and the
    /// focus stays where it was.
    @discardableResult
    func tab(_ direction: TabDirection, from stop: TabStop) -> Bool {
        stop.following(direction).contains { focus($0) }
    }

    func setPanelFocus(for tab: RightPanelTab, _ focus: @escaping () -> Bool) {
        panelFocus[tab] = focus
    }

    private func focus(_ stop: TabStop) -> Bool {
        switch stop {
        case .page: page.focusBody()
        case .panel: shownPanelTab.flatMap { panelFocus[$0] }?() ?? false
        case .searchField: page.desk?.focusFindField() ?? false
        }
    }
}

enum EscapeOutcome {
    case handled, passedOn
}

/// A popover in the window, which Esc closes first.
enum WindowPopover: Hashable {
    case palette(TextPart, PaletteKind)
}

/// Esc for a layer whose focus may be in SwiftUI's controls (a sheet, File a Copy's dialog, a
/// palette): a key equivalent, which AppKit offers before the focused control sees the key. Never
/// a Tab stop, even with Full Keyboard Access on.
struct EscapeKey: View {
    let keys: WindowKeys?

    var body: some View {
        Button("") { keys?.escape() }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.plain)
            .focusable(false)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// The window's Esc and Tab, for views made from AppKit ones.
    @Entry var windowKeys: WindowKeys?
}
