import SceneItCore
import SwiftUI

/// Where the control bars and the Format menu send `FormattingCommand`s (PLAN §6.2, §11), and
/// what they show: the selection of the editor that can be formatted now, the page or the
/// notes. That's only the one with the focus, and only while it can be edited; never while the
/// title field has the focus (decision 0015), under a sheet, or in a read-only book. So at most
/// one bar is active, the one beside that editor, and the menu acts on the same editor.
///
/// One per window (ADR 0021), so the menu finds the editor without asking which window is key.
@Observable
final class EditorFormatting {
    let preferences: AppPreferences
    /// `nil` while no editor can be formatted.
    private(set) var active: Active?
    @ObservationIgnored private weak var editor: SceneTextEditor?

    /// The editor that can be formatted, its selection's formats, and whether a new comment
    /// could cover its selection.
    struct Active: Equatable {
        let part: TextPart
        let selection: SelectionFormatting
        let comments: CommentTarget
    }

    /// What a new comment on the active editor's selection would cover.
    enum CommentTarget: Equatable {
        /// No selection, only line breaks, or the notes (ADR 0035).
        case nothing
        case selection
    }

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    /// The active editor's selection, for the Format menu.
    var selection: SelectionFormatting? {
        active?.selection
    }

    /// The page's editor while it can be formatted and its selection can take a new comment
    /// (Edit → New Comment, ADR 0037).
    var commentablePage: SceneTextEditor? {
        active?.part == .body && active?.comments == .selection ? editor : nil
    }

    /// The selection a bar beside `part`'s editor shows; `nil` while that bar is inactive.
    func selection(in part: TextPart) -> SelectionFormatting? {
        active?.part == part ? active?.selection : nil
    }

    func perform(_ command: FormattingCommand) {
        guard active != nil, let editor, editor.format(command) else { return }
        preferences.remember(command)
    }

    func state(of command: FormattingCommand) -> ControlState? {
        selection?.state(of: command)
    }

    func state(of command: FormattingCommand, in part: TextPart) -> ControlState? {
        selection(in: part)?.state(of: command)
    }

    /// Called by an editor whenever its selection, focus or editability changes: `nil` when it
    /// can't be formatted. An editor that can't be formatted leaves another's selection be, so
    /// the order the focus leaves one and reaches the other doesn't matter.
    func show(
        _ selection: SelectionFormatting?, commenting comments: CommentTarget = .nothing,
        from editor: SceneTextEditor
    ) {
        let new: Active?
        if let selection {
            self.editor = editor
            new = Active(part: editor.part, selection: selection, comments: comments)
        } else if self.editor === editor || self.editor == nil {
            new = nil
        } else {
            return
        }
        if active != new { active = new }
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
