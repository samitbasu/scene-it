import SceneItCore
import SwiftUI

/// The window toolbar (PLAN §4.1). Undo and Redo act on the focused text (`UndoRoute`); their
/// graying out and zoom arrive with #16, Print with #35 and Export to Word with #37; until then
/// those are present and disabled. File a copy… is only for a book open for editing.
struct WindowToolbar: ToolbarContent {
    let book: AppOpenBook
    let filing: FilingFlow

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Breadcrumb(book: book)
                .padding(.horizontal, 8)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem {
            ControlGroup {
                Button(WindowWording.undo, systemImage: "arrow.uturn.backward") { UndoRoute.undo.send() }
                Button(WindowWording.redo, systemImage: "arrow.uturn.forward") { UndoRoute.redo.send() }
            }
            .disabled(!book.isEditable)
        }
        ToolbarItem {
            ControlGroup {
                Button(WindowWording.zoomOut, systemImage: "minus") {}
                    .disabled(true)
                Text(WindowWording.zoom(.standard))
                    .monospacedDigit()
                    .frame(minWidth: 44)
                Button(WindowWording.zoomIn, systemImage: "plus") {}
                    .disabled(true)
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
            Button(WindowWording.fileACopy, systemImage: "archivebox") { filing.begin() }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(!book.isEditable || filing.draft != nil)
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

/// Where the toolbar's Undo and Redo go: the same action Cmd+Z sends, to the focused view, so a
/// text view acts on its own undo manager (the page's comes from `OpenBook.pageUndo(for:)`).
/// #16 routes them to `OpenBook.structureUndo` while the Scenes sheet is open (PLAN §8.6).
enum UndoRoute {
    case undo, redo

    func send() {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    var selector: Selector {
        switch self {
        case .undo: Selector(("undo:"))
        case .redo: Selector(("redo:"))
        }
    }
}
