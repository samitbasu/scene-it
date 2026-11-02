import SceneItCore
import SwiftUI

// The toolbar's controls (PLAN §4.1), shared by both toolbar candidates. Undo/Redo and zoom
// arrive with #16, Print with #35, Export to Word with #37 and File a copy with #32; until
// then they're present and disabled.

struct Breadcrumb: View {
    let book: AppOpenBook

    var body: some View {
        let parts = WindowWording.breadcrumb(book: book.book, openScene: book.openScene)
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

struct UndoRedoButtons: View {
    var body: some View {
        ControlGroup {
            Button(WindowWording.undo, systemImage: "arrow.uturn.backward") {}
            Button(WindowWording.redo, systemImage: "arrow.uturn.forward") {}
        }
        .disabled(true)
    }
}

struct ZoomControl: View {
    let book: AppOpenBook

    var body: some View {
        ControlGroup {
            Button(WindowWording.zoomOut, systemImage: "minus") {}
                .disabled(true)
            Text(WindowWording.zoom(book.book.settings.zoom))
                .monospacedDigit()
                .frame(minWidth: 44)
            Button(WindowWording.zoomIn, systemImage: "plus") {}
                .disabled(true)
        }
    }
}

struct PrintButton: View {
    var body: some View {
        Button(WindowWording.print, systemImage: "printer") {}
            .disabled(true)
    }
}

struct ExportButton: View {
    var body: some View {
        Button(WindowWording.exportToWord, systemImage: "doc.text") {}
            .disabled(true)
    }
}

struct FileACopyButton: View {
    var body: some View {
        Button(WindowWording.fileACopy, systemImage: "archivebox") {}
            .buttonStyle(.borderedProminent)
            .disabled(true)
    }
}

/// c1: the controls in the system's window toolbar.
struct NativeToolbar: ViewModifier {
    let book: AppOpenBook
    @Environment(\.windowLook) private var look

    func body(content: Content) -> some View {
        if look.toolbar == .native {
            content.toolbar {
                ToolbarItem(placement: .navigation) {
                    Breadcrumb(book: book)
                        .padding(.horizontal, 8)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem { UndoRedoButtons() }
                ToolbarItem { ZoomControl(book: book) }
                ToolbarSpacer(.fixed)
                ToolbarItem { PrintButton().labelStyle(.titleAndIcon) }
                ToolbarItem { ExportButton().labelStyle(.titleAndIcon) }
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    FileACopyButton().labelStyle(.titleAndIcon)
                }
            }
        } else {
            content
        }
    }
}

/// c2: the controls in a bar drawn in the window, like the mockup. The window's title bar is
/// hidden, so the bar leaves room for the window buttons.
struct CustomToolbar: View {
    let book: AppOpenBook

    var body: some View {
        HStack(spacing: 12) {
            Breadcrumb(book: book)
            Spacer()
            UndoRedoButtons()
                .fixedSize()
            ZoomControl(book: book)
                .fixedSize()
            Group {
                PrintButton()
                ExportButton()
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            FileACopyButton()
                .labelStyle(.titleAndIcon)
        }
        .controlSize(.regular)
        .padding(.leading, 80)
        .padding(.trailing, 12)
        .frame(height: 48)
    }
}
