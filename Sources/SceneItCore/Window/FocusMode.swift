/// Focus mode (PLAN §4.6): the page alone, the rest of the window's chrome hidden. It's the
/// window's own state, never a preference: it changes nothing the chrome keeps (the right
/// panel's open state, the open sheet), so leaving it shows the chrome exactly as it was.
public enum FocusMode: Hashable, Sendable {
    case off, on

    public var toggled: FocusMode {
        self == .off ? .on : .off
    }

    /// Whether the window shows `part` under `rules`.
    public func shows(_ part: ChromePart, under rules: FocusModeRules) -> Bool {
        switch (self, part) {
        case (.off, _): true
        case (.on, .formattingBar): rules.formattingBar == .shown
        case (.on, .rail), (.on, .toolbar), (.on, .rightPanel), (.on, .statusBar): false
        }
    }

    /// After `event`, under `rules`.
    public func after(_ event: FocusModeEvent, under rules: FocusModeRules) -> FocusMode {
        switch event {
        case .sceneOpened where rules.sceneSwitch == .leavesFocusMode: .off
        case .sheetOpened where rules.sheets == .leaveFocusMode: .off
        case .sceneOpened, .sheetOpened: self
        }
    }
}

/// The window's parts around the page.
public enum ChromePart: CaseIterable, Hashable, Sendable {
    case rail, toolbar, rightPanel, statusBar, formattingBar
}

/// What can happen while focus mode is on, other than leaving it.
public enum FocusModeEvent: Hashable, Sendable {
    case sceneOpened, sheetOpened
}

/// The answers to what PLAN §4.6 leaves open (#21), each a switch. `recommended` is what the
/// app ships until the owner picks.
public struct FocusModeRules: Hashable, Sendable {
    public var formattingBar: FormattingBarInFocusMode
    public var sceneSwitch: SceneSwitchInFocusMode
    public var sheets: SheetsInFocusMode

    public init(
        formattingBar: FormattingBarInFocusMode, sceneSwitch: SceneSwitchInFocusMode,
        sheets: SheetsInFocusMode
    ) {
        self.formattingBar = formattingBar
        self.sceneSwitch = sceneSwitch
        self.sheets = sheets
    }

    public static let recommended = FocusModeRules(
        formattingBar: .shown, sceneSwitch: .staysInFocusMode, sheets: .openOverFocusMode)
}

public enum FormattingBarInFocusMode: Hashable, Sendable {
    case shown, hidden
}

public enum SceneSwitchInFocusMode: Hashable, Sendable {
    case staysInFocusMode, leavesFocusMode
}

/// A sheet (Scenes, Search, File Cabinet) or File a Copy's dialog opened from the menu while
/// focus mode is on.
public enum SheetsInFocusMode: Hashable, Sendable {
    /// It opens over the page; closing it goes back to focus mode.
    case openOverFocusMode
    case leaveFocusMode
}
