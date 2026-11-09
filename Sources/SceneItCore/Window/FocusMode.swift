/// Focus mode (PLAN §4.6): the page alone, the rest of the window's chrome hidden. It's the
/// window's own state, never a preference: it changes nothing the chrome keeps (the right
/// panel's open state, the open sheet), so leaving it shows the chrome exactly as it was. A book
/// always opens out of it, and opening another scene or a sheet leaves it on (the owner, #21).
public enum FocusMode: Hashable, Sendable {
    case off, on

    public var toggled: FocusMode {
        self == .off ? .on : .off
    }

    /// Whether the window shows `part`. The formatting bar isn't chrome here: it stays, for
    /// formatting (the owner, #21).
    public func shows(_ part: ChromePart) -> Bool {
        switch part {
        case .rail, .toolbar, .rightPanel, .statusBar: self == .off
        }
    }
}

/// The window's parts around the page that focus mode hides.
public enum ChromePart: CaseIterable, Hashable, Sendable {
    case rail, toolbar, rightPanel, statusBar
}
