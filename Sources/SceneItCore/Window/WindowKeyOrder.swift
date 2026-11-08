/// Whether a layer of the window is up.
public enum Presence: Hashable, Sendable {
    case absent, present
}

/// What's up in the window, as far as Esc is concerned.
public struct EscapeContext: Hashable, Sendable {
    public var popover: Presence
    public var dialog: Presence
    public var mode: WindowMode
    public var focusMode: FocusMode

    public init(popover: Presence, dialog: Presence, mode: WindowMode, focusMode: FocusMode) {
        self.popover = popover
        self.dialog = dialog
        self.mode = mode
        self.focusMode = focusMode
    }
}

/// What Esc closes, in the order it closes them (PLAN §8.4): popovers first, then dialogs and
/// sheets, then focus mode. Every Esc in the window asks `closedByEscape(in:)`.
///
/// Menus come before all of these, and need no case: while a menu is open, AppKit's menu
/// tracking takes every key, so Esc closes it and no Esc of ours runs.
public enum EscapeLayer: CaseIterable, Hashable, Sendable {
    /// A formatting bar's palette.
    case popover
    /// File a Copy's dialog, a sheet attached to the window.
    case dialog
    /// A rail sheet: Scenes, Search or File Cabinet.
    case sheet
    case focusMode

    /// The layer Esc closes: the first that's up. `nil` when none is, and the focused view's
    /// own Esc applies (a comment card's edit ends; the Errors tab hands the focus back).
    public static func closedByEscape(in context: EscapeContext) -> EscapeLayer? {
        allCases.first { $0.isUp(in: context) }
    }

    private func isUp(in context: EscapeContext) -> Bool {
        switch self {
        case .popover: context.popover == .present
        case .dialog: context.dialog == .present
        case .sheet: context.mode.isSheet
        case .focusMode: context.focusMode == .on
        }
    }
}

/// Where Tab moves the focus (PLAN §8.4), in the order it moves: the page, the right panel, the
/// search field, and round again.
public enum TabStop: CaseIterable, Hashable, Sendable {
    /// The scene's title or its body. (Within the page, Tab goes from the title to the body:
    /// ADR 0015.)
    case page
    /// The panel's editor, or its first control.
    case panel
    /// The page's find bar's field, while the find bar shows.
    case searchField

    /// The stops to try after `self`, nearest first: each in turn until one takes the focus.
    /// `self` isn't among them, so a Tab with nowhere else to go leaves the focus where it is.
    public func following(_ direction: TabDirection) -> [TabStop] {
        let all = Self.allCases
        let ordered = direction == .forward ? all : all.reversed()
        guard let index = ordered.firstIndex(of: self) else { return [] }
        return Array(ordered[(index + 1)...] + ordered[..<index])
    }
}

public enum TabDirection: Hashable, Sendable {
    case forward, backward
}
