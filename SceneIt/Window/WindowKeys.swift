import AppKit
import SceneItCore
import SwiftUI

/// One window's Esc and Tab (PLAN §8.4). Every view that takes Esc asks `escape()`, which
/// closes what `EscapeLayer` says; every view that Tab leaves asks `tab(_:from:)`, which tries
/// the stops in `TabStop`'s order. So the order of each is in one place, and no view can
/// disagree with it.
@MainActor
@Observable
final class WindowKeys {
    /// The palette open in a formatting bar, if one is.
    var popover: WindowPopover?
    @ObservationIgnored private let chrome: WindowChrome
    @ObservationIgnored let filing: FilingFlow
    @ObservationIgnored private let page: PageFocus
    @ObservationIgnored private let mode: Binding<WindowMode>
    /// The right panel's tab while the panel shows; `nil` while it's collapsed or hidden.
    @ObservationIgnored var shownPanelTab: RightPanelTab?
    /// How each tab takes the focus: its editor, or its first control.
    @ObservationIgnored private var panelFocus: [RightPanelTab: () -> Bool] = [:]

    init(chrome: WindowChrome, filing: FilingFlow, page: PageFocus, mode: Binding<WindowMode>) {
        self.chrome = chrome
        self.filing = filing
        self.page = page
        self.mode = mode
    }

    var escapeContext: EscapeContext {
        EscapeContext(
            popover: popover == nil ? .absent : .present, dialog: filing.draft == nil ? .absent : .present,
            mode: mode.wrappedValue, focusMode: chrome.focusMode)
    }

    /// Closes what Esc closes now, or says there's nothing, so the focused view's own Esc applies.
    @discardableResult
    func escape() -> EscapeOutcome {
        guard let layer = EscapeLayer.closedByEscape(in: escapeContext) else { return .passedOn }
        switch layer {
        case .popover: popover = nil
        case .dialog: filing.cancel()
        case .sheet: mode.wrappedValue = mode.wrappedValue.closingSheet
        case .focusMode: chrome.set(.off)
        }
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
/// palette): a key equivalent, which AppKit offers before the focused control sees the key.
struct EscapeKey: View {
    let keys: WindowKeys?

    var body: some View {
        Button("") { keys?.escape() }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// The window's Esc and Tab, for views made from AppKit ones.
    @Entry var windowKeys: WindowKeys?
}
