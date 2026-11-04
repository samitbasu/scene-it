import SceneItCore
import SwiftUI

/// Edit → New Comment, Cmd+Shift+M (PLAN §11, with ADR 0037's shortcut), on the page while it
/// has the focus, can be edited and has a selection (`EditorFormatting.commentablePage`, which the
/// comments panel's buttons ask too).
struct CommentCommands: Commands {
    let formatting: EditorFormatting

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(CommentWording.newComment) { formatting.commentablePage?.newCommentInItsCard() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(formatting.commentablePage == nil)
        }
    }
}
