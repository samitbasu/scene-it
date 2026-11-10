import SceneItCore
import SwiftUI

/// The window toolbar (PLAN §4.1). Undo and Redo go where `UndoRouter` says; Print and Export to
/// Word go through the window's own flows, as the File menu does. File a copy… is only for a book
/// open for editing and not being closed (`FilingFlow.canBegin`).
struct WindowToolbar: ToolbarContent {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    let undo: UndoRouter
    let filing: FilingFlow
    let printing: PrintFlow
    let wordExport: WordExportFlow

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
                zoomButton(.zoomOut, systemImage: "minus")
                Text(WindowWording.zoom(preferences.zoom))
                    .monospacedDigit()
                    .frame(minWidth: 44)
                zoomButton(.zoomIn, systemImage: "plus")
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button(WindowWording.print, systemImage: "printer") { printing.begin() }
                .labelStyle(.titleAndIcon)
                .disabled(!printing.canBegin)
        }
        ToolbarItem {
            Button(WindowWording.exportToWord, systemImage: "doc.text") {
                Task { await wordExport.begin() }
            }
            .labelStyle(.titleAndIcon)
            .disabled(!wordExport.canBegin)
        }
        if book.document.kind != .filedCopy {
            fileACopy
        }
    }

    /// Hidden over a filed copy (PLAN §4.1).
    @ToolbarContentBuilder private var fileACopy: some ToolbarContent {
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button(WindowWording.fileACopy, systemImage: "archivebox") { filing.begin() }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(!filing.canBegin(in: store))
        }
    }

    private func zoomButton(_ step: ZoomStep, systemImage: String) -> some View {
        Button(WindowWording.zoomStep(step), systemImage: systemImage) { preferences.zoom(step) }
            .help(WindowWording.zoomStep(step))
            .disabled(!preferences.canZoom(step))
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
