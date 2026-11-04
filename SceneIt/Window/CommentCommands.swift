import SceneItCore
import SwiftUI

/// Edit → New Comment (PLAN §11), on the focused window's page while the page has the focus
/// and can be edited.
struct CommentCommands: Commands {
    @FocusedValue(\.sceneEditors) private var editors

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(CommentWording.newComment) { editors?.page.editor.newComment() }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(editors?.canComment != true)
        }
    }
}

extension FocusedValues {
    @Entry var sceneEditors: SceneEditors?
}
