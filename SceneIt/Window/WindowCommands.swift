import SceneItCore
import SwiftUI

/// The View menu's sheets and the right panel (PLAN §11).
struct WindowCommands: Commands {
    let books: BookController
    @FocusedBinding(\.windowMode) private var mode

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(WindowMode.allCases.filter(\.isSheet), id: \.self) { sheet in
                Button(WindowWording.railName(sheet)) { mode = mode?.choosing(sheet) }
                    .keyboardShortcut(Self.shortcut(for: sheet))
                    .disabled(mode == nil)
            }
            Button(WindowWording.toggleRightPanel) { books.preferences.toggleRightPanel() }
                .keyboardShortcut("]")
                .disabled(books.store.current == nil)
            Divider()
        }
    }

    private static func shortcut(for sheet: WindowMode) -> KeyboardShortcut? {
        switch sheet {
        case .scenes: KeyboardShortcut("1")
        case .search: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .page, .fileCabinet: nil
        }
    }
}
