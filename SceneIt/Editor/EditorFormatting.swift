import SceneItCore
import SwiftUI

/// Where the control bars and the Format menu send `FormattingCommand`s (PLAN §6.2, §11), and
/// where Edit → New Comment, the page's Comment button and the comments panel's + find the page
/// (ADR 0037): the editor with the focus, the page or the notes, while it takes formats or
/// comments. Never while the title field has the focus (decision 0015), under a sheet, or in a
/// read-only book. So at most one bar is active, the one beside that editor, and the menus act
/// on the same editor.
/// A review's page (ADR 0042) is active for comments alone: its bar and the Format menu stay off.
///
/// One per window (ADR 0038), so the menu finds the editor without asking which window is key.
@Observable
final class EditorFormatting {
    let preferences: AppPreferences
    /// `nil` while no editor with the focus takes formats or comments.
    private(set) var active: Active?
    @ObservationIgnored private weak var editor: SceneTextEditor?

    /// The editor with the focus, whether its text can be formatted, and whether a new
    /// comment could cover its selection.
    struct Active: Equatable {
        let part: TextPart
        let formats: Formats
        let comments: CommentTarget
    }

    /// Whether the active editor's text can be formatted.
    enum Formats: Equatable {
        /// It can: the selection's formats.
        case changeable(SelectionFormatting)
        /// Its text can't change, but comments on it can: a review's page (ADR 0042).
        case fixed

        var selection: SelectionFormatting? {
            guard case .changeable(let selection) = self else { return nil }
            return selection
        }
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

    /// The active editor's selection, for the Format menu; `nil` while it can't be formatted.
    var selection: SelectionFormatting? {
        active?.formats.selection
    }

    /// The page's editor while it has the focus and its selection can take a new comment (Edit →
    /// New Comment, ADR 0037), on a review's page as on a book's.
    var commentablePage: SceneTextEditor? {
        active?.part == .body && active?.comments == .selection ? editor : nil
    }

    /// The selection a bar beside `part`'s editor shows; `nil` while that bar is inactive.
    func selection(in part: TextPart) -> SelectionFormatting? {
        active?.part == part ? active?.formats.selection : nil
    }

    func perform(_ command: FormattingCommand) {
        guard selection != nil, let editor, editor.format(command) else { return }
        preferences.remember(command)
    }

    func state(of command: FormattingCommand) -> ControlState? {
        selection?.state(of: command)
    }

    func state(of command: FormattingCommand, in part: TextPart) -> ControlState? {
        selection(in: part)?.state(of: command)
    }

    /// Called by an editor whenever its selection, focus or editability changes: `nil` when it
    /// takes neither formats nor comments. Such an editor leaves another's selection be, so the
    /// order the focus leaves one and reaches the other doesn't matter.
    func show(
        _ formats: Formats?, commenting comments: CommentTarget = .nothing, from editor: SceneTextEditor
    ) {
        let new: Active?
        if let formats {
            self.editor = editor
            new = Active(part: editor.part, formats: formats, comments: comments)
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
