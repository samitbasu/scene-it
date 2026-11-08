import AppKit
import SceneItCore
import SwiftUI

/// One window's Esc and Tab (PLAN §8.4). `escape(from:)` closes what `EscapeLayer` says, and
/// `tab(_:from:)` tries the stops in `TabStop`'s order, so each order is in one place.
///
/// Every Esc in the window asks `escape(from:)` first: the page, the notes and the title; comment
/// cards, Comments' search field and the Errors tab; the page's find bar field; and `EscapeKey`
/// in the sheets, File a Copy's dialog and the palettes; and, when no view took it, the window
/// itself (`WindowEscapeFallback`). The one exception is the notes' own find bar, whose Esc stays
/// AppKit's: it closes that bar.
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

    /// File a Copy's dialog counts only while it's on screen: a draft whose sheet went (until File
    /// a Copy… shows it again) can't be cancelled by an Esc meant for the page.
    var escapeContext: EscapeContext {
        let dialogShown = filing.draft != nil && !filing.presentationLost
        return EscapeContext(
            popover: popover == nil ? .absent : .present, dialog: dialogShown ? filing.stage : nil,
            mode: mode.wrappedValue, findBar: page.desk?.findField == nil ? .absent : .present,
            focusMode: chrome.focusMode)
    }

    /// Closes what Esc closes now, or says there's nothing, so the focused view's own Esc applies.
    @discardableResult
    func escape(from entrance: EscapeEntrance) -> EscapeOutcome {
        act(on: EscapeLayer.escape(in: escapeContext), from: entrance, restoring: nil)
    }

    /// `escape(from:)` for a SwiftUI field, which is still handling the key: what Esc closes is
    /// decided now, and closed on the next turn, only if it's still what Esc would close. Moving
    /// the focus while the field handles its key (as closing the find bar does) loses what was
    /// typed in it.
    func escapeAfterThisKey(from entrance: EscapeEntrance) -> EscapeOutcome {
        let decided = EscapeLayer.escape(in: escapeContext)
        if decided == .passOn { return .passedOn }
        let focus = page.currentFocus
        DispatchQueue.main.async { [weak self] in
            guard let self, EscapeLayer.escape(in: self.escapeContext) == decided else { return }
            _ = self.act(on: decided, from: entrance, restoring: focus)
        }
        return .handled
    }

    #if DEBUG
        /// The last Esc that reached the window's keys: where it came in and what it did, for the
        /// tests.
        @ObservationIgnored private(set) var lastEscape: (entrance: EscapeEntrance, result: EscapeResult)?
    #endif

    private func act(
        on result: EscapeResult, from entrance: EscapeEntrance, restoring focus: PageFocus.Focus?
    )
        -> EscapeOutcome
    {
        #if DEBUG
            lastEscape = (entrance, result)
        #endif
        switch result {
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

/// Where an Esc reached the window's keys.
enum EscapeEntrance: Equatable {
    /// `EscapeKey`, the key equivalent in a sheet, the dialog or a palette.
    case keyEquivalent
    /// The focused view's own handling: a text view, a field, a card, the Errors tab.
    case focusedView
    /// `WindowEscapeFallback`: no view took it.
    case window
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
        Button("") { keys?.escape(from: .keyEquivalent) }
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
