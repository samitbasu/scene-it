import SceneItCore
import SwiftUI

/// The Format menu (PLAN §11): Bold, Italic, Strikethrough, Text Color ▸ and Highlight ▸,
/// performing the same `FormattingCommand`s as the control bar.
struct FormatCommands: Commands {
    let formatting: PageFormatting

    var body: some Commands {
        CommandMenu(WindowWording.formatMenu) {
            ForEach(TextStyle.allCases, id: \.self) { style in
                item(.toggle(style))
            }
            Divider()
            Menu(WindowWording.textColor) {
                ForEach(FormattingCommand.textColors, id: \.self, content: item)
            }
            Menu(WindowWording.highlight) {
                ForEach(FormattingCommand.highlights, id: \.self, content: item)
            }
        }
    }

    private func item(_ command: FormattingCommand) -> some View {
        Button(WindowWording.menuItem(command)) { formatting.perform(command) }
            .keyboardShortcut(command.shortcut)
            .disabled(formatting.selection == nil)
    }
}
