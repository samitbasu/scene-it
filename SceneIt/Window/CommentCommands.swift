import SceneItCore
import SwiftUI

/// Edit → New Comment, Cmd+Shift+M (PLAN §11, with ADR 0037's shortcut), on the page while it
/// has the focus, takes comments (a review's page too) and has a selection a comment can cover;
/// the menu finds it through `EditorFormatting`, as the Format menu and the comments panel's
/// buttons do. The new comment's card opens with the cursor in it.
struct CommentCommands: Commands {
    let formatting: EditorFormatting

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(CommentWording.newComment) { formatting.commentablePage?.newCommentInItsCard() }
                .keyboardShortcut(.newComment)
                .disabled(formatting.commentablePage == nil)
        }
    }
}

extension KeyboardShortcut {
    /// New Comment's (ADR 0037), which its menu item has and the panel's buttons name.
    static let newComment = KeyboardShortcut("m", modifiers: [.command, .shift])

    /// As the app's help spells shortcuts: "Cmd+Shift+M".
    var spelled: String {
        let names: [(EventModifiers, String)] = [
            (.command, "Cmd"), (.control, "Ctrl"), (.option, "Option"), (.shift, "Shift"),
        ]
        let held = names.filter { modifiers.contains($0.0) }.map(\.1)
        return (held + [key.character.uppercased()]).joined(separator: "+")
    }
}
