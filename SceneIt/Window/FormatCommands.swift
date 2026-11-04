import SceneItCore
import SwiftUI

/// The Format menu (PLAN §11): Bold, Italic, Strikethrough, Text Color ▸ and Highlight ▸,
/// performing the same `FormattingCommand`s as the control bars, on the editor that has the
/// focus, the page or the notes. The selection's color and
/// highlight are checked in their submenus; a selection of several has no check.
struct FormatCommands: Commands {
    let formatting: EditorFormatting

    var body: some Commands {
        CommandMenu(WindowWording.formatMenu) {
            ForEach(TextStyle.allCases, id: \.self) { style in
                Button(WindowWording.menuItem(.toggle(style))) { formatting.perform(.toggle(style)) }
                    .keyboardShortcut(FormattingCommand.toggle(style).shortcut)
                    .disabled(formatting.selection == nil)
            }
            Divider()
            Menu(WindowWording.textColor) {
                ForEach(FormattingCommand.textColors, id: \.self, content: checkedItem)
            }
            Menu(WindowWording.highlight) {
                ForEach(FormattingCommand.highlights, id: \.self, content: checkedItem)
            }
        }
    }

    /// Choosing an item applies its color even when it's already checked: colors never toggle.
    private func checkedItem(_ command: FormattingCommand) -> some View {
        Toggle(
            WindowWording.menuItem(command),
            isOn: Binding(
                get: { formatting.state(of: command) == .on },
                set: { _ in formatting.perform(command) })
        )
        .keyboardShortcut(command.shortcut)
        .disabled(formatting.selection == nil)
    }
}
