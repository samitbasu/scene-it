/// Whether a layer of the window is up.
public enum Presence: Hashable, Sendable {
    case absent, present
}

/// What's up in the window, as far as Esc is concerned.
public struct EscapeContext: Hashable, Sendable {
    public var popover: Presence
    /// A dialog attached to the window, and its stage while it's up.
    public var dialog: DialogStage?
    public var mode: WindowMode
    /// The page's find bar.
    public var findBar: Presence
    public var focusMode: FocusMode

    public init(
        popover: Presence, dialog: DialogStage?, mode: WindowMode, findBar: Presence, focusMode: FocusMode
    ) {
        self.popover = popover
        self.dialog = dialog
        self.mode = mode
        self.findBar = findBar
        self.focusMode = focusMode
    }
}

/// What Esc closes, in the order it closes them (PLAN §8.4): popovers first, then the dialog and
/// sheets, then the page's find bar, then focus mode. `EscapeLayer.escape(in:)` is the one place
/// that order lives.
///
/// Menus come before all of these, and need no case: while a menu is open, AppKit's menu
/// tracking takes every key, so Esc closes it and no Esc of ours runs.
public enum EscapeLayer: CaseIterable, Hashable, Sendable {
    /// A formatting bar's palette.
    case popover
    /// A dialog attached to the window as a sheet: File a Copy's, or Export as SceneIt's chooser.
    case dialog
    /// A rail sheet: Scenes, Search or File Cabinet. It covers the find bar.
    case sheet
    /// The page's find bar (⌘F).
    case findBar
    case focusMode

    /// What Esc does: close the first layer that's up, or nothing while that layer can't close
    /// (File a Copy's dialog while it files: closing it would drop what was typed, which a failed
    /// filing still needs). `.passOn` when no layer is up, and the focused view's own Esc
    /// applies (a comment card's edit ends; the Errors tab hands the focus back).
    public static func escape(in context: EscapeContext) -> EscapeResult {
        guard let layer = allCases.first(where: { $0.isUp(in: context) }) else { return .passOn }
        return layer.canClose(in: context) ? .close(layer) : .hold(layer)
    }

    private func isUp(in context: EscapeContext) -> Bool {
        switch self {
        case .popover: context.popover == .present
        case .dialog: context.dialog != nil
        case .sheet: context.mode.isSheet
        case .findBar: context.findBar == .present
        case .focusMode: context.focusMode == .on
        }
    }

    private func canClose(in context: EscapeContext) -> Bool {
        switch self {
        case .dialog: context.dialog != .busy
        case .popover, .sheet, .findBar, .focusMode: true
        }
    }

    /// Who takes a plain Esc that the window offers as a key equivalent while no view in it has
    /// the focus, with `context` up: the top layer's own Esc key equivalent, which shares the window
    /// that hears the key and may first close something inside the layer, or else the window's.
    public static func keyEquivalentTaker(in context: EscapeContext) -> EscapeKeyTaker {
        escape(in: context).layer?.keyEquivalentTaker ?? .window
    }

    /// A rail sheet's Esc key equivalent is in the book window, and a dialog's in the dialog's
    /// window, beside a window fallback each. A palette's is in its popover's own window.
    private var keyEquivalentTaker: EscapeKeyTaker {
        switch self {
        case .dialog, .sheet: .layer
        case .popover, .findBar, .focusMode: .window
        }
    }
}

/// Which of two Esc key equivalents in one window takes a plain Esc: the top layer's, or the
/// window's own.
public enum EscapeKeyTaker: Hashable, Sendable {
    case layer, window
}

/// Whether a dialog can close: `busy` while it's doing what it was opened for, and closing it
/// would lose something (File a Copy's dialog while it files).
public enum DialogStage: Hashable, Sendable {
    case open, busy
}

public enum EscapeResult: Hashable, Sendable {
    case close(EscapeLayer)
    /// The top layer stays, and so does everything under it.
    case hold(EscapeLayer)
    case passOn

    /// The layer Esc closes or holds.
    public var layer: EscapeLayer? {
        switch self {
        case .close(let layer), .hold(let layer): layer
        case .passOn: nil
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
