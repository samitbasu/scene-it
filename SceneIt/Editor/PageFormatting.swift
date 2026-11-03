import SceneItCore
import SwiftUI

/// Where the control bar and the Format menu send `FormattingCommand`s (PLAN §6.2, §11), and
/// what they show: the page's selection, while the page can be formatted. That's only while it
/// has the focus and can be edited; never while the title field has it (decision 0015), under
/// a sheet, or in a read-only book.
///
/// One per window (ADR 0021), so the menu finds the page without asking which window is key.
@Observable
final class PageFormatting {
    let preferences: AppPreferences
    /// `nil` while the page can't be formatted.
    private(set) var selection: SelectionFormatting?
    @ObservationIgnored weak var editor: PageEditor?

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func perform(_ command: FormattingCommand) {
        guard selection != nil, let editor, editor.format(command) else { return }
        preferences.remember(command)
    }

    func state(of command: FormattingCommand) -> ControlState? {
        selection?.state(of: command)
    }

    /// Called by the page whenever its selection, focus or editability changes.
    func show(_ selection: SelectionFormatting?) {
        if self.selection != selection { self.selection = selection }
    }

    /// The command the bar's color button applies: the last color chosen from its palette.
    var lastTextColor: FormattingCommand {
        .textColor(PaletteColor(preferences.lastTextColor))
    }

    var lastHighlight: FormattingCommand {
        .highlight(preferences.lastHighlight)
    }
}

extension FormattingCommand {
    /// PLAN §11 and decision 0027: Ctrl+Cmd+1…7 in palette order; highlights have none.
    var shortcut: KeyboardShortcut? {
        switch self {
        case .toggle(.bold): KeyboardShortcut("b")
        case .toggle(.italic): KeyboardShortcut("i")
        case .toggle(.strike): KeyboardShortcut("x", modifiers: [.command, .shift])
        case .textColor(let color):
            PaletteColor.allCases.firstIndex(of: color).map {
                KeyboardShortcut(KeyEquivalent(Character(String($0 + 1))), modifiers: [.control, .command])
            }
        case .highlight: nil
        }
    }
}
