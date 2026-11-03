import SceneItCore
import SwiftUI

/// The View menu (PLAN §11): the sheets, the right panel, zoom, and stepping through the story;
/// and Edit → Undo and Redo.
struct WindowCommands: Commands {
    let books: BookController
    @FocusedBinding(\.windowMode) private var mode
    @FocusedValue(\.page) private var page

    var body: some Commands {
        UndoCommands()
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
            zoom
            Divider()
            ForEach(SceneStep.allCases, id: \.self) { step in
                Button(WindowWording.sceneStep(step)) { take(step) }
                    .keyboardShortcut(Self.shortcut(for: step))
                    .disabled(destination(of: step) == nil)
            }
            Divider()
        }
    }

    @ViewBuilder private var zoom: some View {
        let preferences = books.preferences
        let noBook = books.store.current == nil
        Button(WindowWording.zoomIn) { preferences.setZoom(preferences.zoom.zoomedIn) }
            .keyboardShortcut("=")
            .disabled(noBook || !preferences.zoom.canZoomIn)
        Button(WindowWording.zoomOut) { preferences.setZoom(preferences.zoom.zoomedOut) }
            .keyboardShortcut("-")
            .disabled(noBook || !preferences.zoom.canZoomOut)
        Button(WindowWording.actualSize) { preferences.setZoom(.standard) }
            .keyboardShortcut("0")
            .disabled(noBook)
        Button(WindowWording.fitWidth) {
            if let desk = page?.desk { preferences.setZoom(desk.fitWidthZoom) }
        }
        .disabled(noBook || page?.desk == nil)
    }

    private func destination(of step: SceneStep) -> SceneID? {
        books.store.current.flatMap { $0.book.scene(step, from: $0.openScene) }
    }

    /// Opens the scene, showing the page if a sheet covers it.
    private func take(_ step: SceneStep) {
        guard let book = books.store.current, let scene = destination(of: step) else { return }
        book.select(scene)
        mode = mode?.closingSheet
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
