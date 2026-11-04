import SceneItCore
import SwiftUI

/// Edit → New Comment, Cmd+Shift+M (PLAN §11, with ADR 0037's shortcut), on the page while it
/// has the focus and can be edited: exactly when the page can be formatted, so the menu finds it
/// through `EditorFormatting`, as the Format menu does.
struct CommentCommands: Commands {
    let formatting: EditorFormatting

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(CommentWording.newComment) { formatting.page?.newComment() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(formatting.page == nil)
        }
    }
}
