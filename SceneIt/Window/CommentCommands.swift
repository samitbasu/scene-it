import SceneItCore
import SwiftUI

/// Edit → New Comment, Cmd+Shift+M (PLAN §11, with ADR 0037's shortcut), on the page while it
/// has the focus, can be edited and has a selection a comment can cover; the menu finds it
/// through `EditorFormatting`, as the Format menu does.
struct CommentCommands: Commands {
    let formatting: EditorFormatting

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(CommentWording.newComment) { formatting.commentablePage?.newComment() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(formatting.commentablePage == nil)
        }
    }
}
