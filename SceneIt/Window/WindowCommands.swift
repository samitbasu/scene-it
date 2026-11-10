import SceneItCore
import SwiftUI

/// The View menu (PLAN §11): the sheets, the right panel, zoom, and stepping through the story;
/// and Edit → Undo and Redo.
struct WindowCommands: Commands {
    let books: BookController
    @FocusedValue(\.page) private var page

    private var chrome: WindowChrome? {
        books.mainWindowChrome.chrome
    }

    /// Whether a dialog (File a Copy's, Export's chooser) is up over the main window, which a
    /// sheet can't open under.
    private var dialogIsUp: Bool {
        chrome?.keys?.escapeContext.dialog != nil
    }

    /// The main window's page or sheet, while it shows a book.
    private var mode: Binding<WindowMode>? {
        books.mainWindowChrome.mode
    }

    /// Ticked while focus mode is on; choosing it, or its shortcut, enters or leaves.
    private var focusMode: Binding<Bool> {
        Binding(get: { chrome?.focusMode == .on }, set: { chrome?.set($0 ? .on : .off) })
    }

    var body: some Commands {
        UndoCommands()
        // In place of macOS's toolbar group, whose Show/Hide Toolbar is ours (below) so that focus
        // mode can disable it (the owner, #21).
        CommandGroup(replacing: .toolbar) {
            ForEach(WindowMode.allCases.filter(\.isSheet), id: \.self) { sheet in
                Button(WindowWording.railName(sheet)) {
                    if let mode { mode.wrappedValue = mode.wrappedValue.choosing(sheet) }
                }
                .keyboardShortcut(Self.shortcut(for: sheet))
                .disabled(mode == nil || dialogIsUp || !WindowMode.offers(sheet, over: books.store.shown))
            }
            Button(WindowWording.toggleRightPanel) { books.preferences.toggleRightPanel() }
                .keyboardShortcut("]")
                .disabled(books.store.shown == nil || chrome?.focusMode == .on)
            Toggle(WindowWording.focusMode, isOn: focusMode)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(chrome == nil)
            Divider()
            zoom
            Divider()
            ForEach(SceneStep.allCases, id: \.self) { step in
                Button(WindowWording.sceneStep(step)) { take(step) }
                    .keyboardShortcut(Self.shortcut(for: step))
                    .disabled(destination(of: step) == nil)
            }
            Divider()
            let action: ToolbarItemAction = chrome?.toolbarVisibility == .hidden ? .show : .hide
            Button(WindowWording.toolbarItem(action)) { chrome?.toggleToolbar() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(chrome == nil || chrome?.focusMode == .on)
        }
    }

    @ViewBuilder private var zoom: some View {
        let preferences = books.preferences
        let noBook = books.store.shown == nil
        ZoomStepButtons(preferences: preferences, keys: .bound)
            .disabled(noBook)
        Button(WindowWording.fitWidth) {
            if let desk = page?.desk { preferences.setZoom(desk.fitWidthZoom) }
        }
        .disabled(noBook || page?.desk == nil)
    }

    private func destination(of step: SceneStep) -> SceneID? {
        books.scene(step)
    }

    /// Opens the scene, showing the page if a sheet covers it.
    private func take(_ step: SceneStep) {
        guard books.take(step) else { return }
        if let mode { mode.wrappedValue = mode.wrappedValue.closingSheet }
    }

    private static func shortcut(for sheet: WindowMode) -> KeyboardShortcut? {
        switch sheet {
        case .scenes: KeyboardShortcut("1")
        case .search: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .page, .fileCabinet: nil
        }
    }

    private static func shortcut(for step: SceneStep) -> KeyboardShortcut {
        switch step {
        case .previous: KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        case .next: KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }
}
