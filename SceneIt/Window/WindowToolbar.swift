import SceneItCore
import SwiftUI

/// The window toolbar (PLAN §4.1, ADR 0052): the breadcrumb at the leading edge, then at the
/// trailing edge Undo and Redo, the zoom menu, and Print, Export to Word and File a copy… as
/// icons, each group in its own glass capsule. Undo and Redo go where `UndoRouter` says; Print
/// and Export to Word go through the window's own flows, as the File menu does. File a copy… is
/// hidden over a filed copy, and only for a book open for editing and not being closed
/// (`FilingFlow.canBegin`).
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
        ToolbarSpacer(.flexible)
        ToolbarItemGroup {
            Button(WindowWording.undo, systemImage: "arrow.uturn.backward") { undo.undo() }
                .help(undo.state.undo ?? WindowWording.undo)
                .disabled(undo.state.undo == nil || !book.isEditable)
            Button(WindowWording.redo, systemImage: "arrow.uturn.forward") { undo.redo() }
                .help(undo.state.redo ?? WindowWording.redo)
                .disabled(undo.state.redo == nil || !book.isEditable)
        }
        gap
        ToolbarItem {
            ZoomMenu(preferences: preferences)
        }
        gap
        ToolbarItemGroup {
            Group {
                Button(WindowWording.print, systemImage: "printer") { printing.begin() }
                    .help(WindowWording.print)
                    .disabled(!printing.canBegin)
                Button(WindowWording.exportToWord, systemImage: "doc.text") {
                    Task { await wordExport.begin() }
                }
                .help(WindowWording.exportToWord)
                .disabled(!wordExport.canBegin)
                if book.document.kind != .filedCopy {
                    Button(WindowWording.fileACopy, systemImage: "archivebox") { filing.begin() }
                        .help(WindowWording.fileACopy)
                        .disabled(!filing.canBegin(in: store))
                }
            }
            .labelStyle(.iconOnly)
        }
    }

    /// Adjacent items share one glass capsule until a spacer. One fixed spacer leaves the capsules
    /// nearly touching, so the gap between groups is two.
    @ToolbarContentBuilder private var gap: some ToolbarContent {
        ToolbarSpacer(.fixed)
        ToolbarSpacer(.fixed)
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
