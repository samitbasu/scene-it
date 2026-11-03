import SceneItCore
import SwiftUI

/// The window toolbar (PLAN §4.1). Undo and Redo go where `UndoRouter` says; Print arrives with
/// #35, Export to Word with #37 and File a copy with #32, and until then those are disabled.
struct WindowToolbar: ToolbarContent {
    let book: AppOpenBook
    let preferences: AppPreferences
    let undo: UndoRouter

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Breadcrumb(book: book)
                .padding(.horizontal, 8)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem {
            ControlGroup {
                Button(WindowWording.undo, systemImage: "arrow.uturn.backward") { undo.undo() }
                    .help(undo.state.undo ?? WindowWording.undo)
                    .disabled(undo.state.undo == nil)
                Button(WindowWording.redo, systemImage: "arrow.uturn.forward") { undo.redo() }
                    .help(undo.state.redo ?? WindowWording.redo)
                    .disabled(undo.state.redo == nil)
            }
            .disabled(!book.isEditable)
        }
        ToolbarItem {
            ControlGroup {
                Button(WindowWording.zoomOut, systemImage: "minus") {
                    preferences.setZoom(preferences.zoom.zoomedOut)
                }
                .help(WindowWording.zoomOut)
                .disabled(!preferences.zoom.canZoomOut)
                Text(WindowWording.zoom(preferences.zoom))
                    .monospacedDigit()
                    .frame(minWidth: 44)
                Button(WindowWording.zoomIn, systemImage: "plus") {
                    preferences.setZoom(preferences.zoom.zoomedIn)
                }
                .help(WindowWording.zoomIn)
                .disabled(!preferences.zoom.canZoomIn)
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button(WindowWording.print, systemImage: "printer") {}
                .labelStyle(.titleAndIcon)
                .disabled(true)
        }
        ToolbarItem {
            Button(WindowWording.exportToWord, systemImage: "doc.text") {}
                .labelStyle(.titleAndIcon)
                .disabled(true)
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button(WindowWording.fileACopy, systemImage: "archivebox") {}
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
    }
}

/// "My Novel › 1. The ferry": the book in bold, then where the open scene is.
private struct Breadcrumb: View {
    let book: AppOpenBook

    var body: some View {
        let parts = WindowWording.breadcrumb(bookTitle: book.book.title, book.location)
        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("›").foregroundStyle(.secondary)
                }
                Text(part)
                    .fontWeight(index == 0 ? .semibold : .regular)
                    .foregroundStyle(index == 0 ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
    }
}
