import SceneItCore
import SwiftUI

/// A rail sheet, over the page and the right panel (PLAN §4.2). Empty until #28 (Scenes),
/// #31 (Search) and #33 (File Cabinet) fill them; × or Esc closes it.
struct SheetPlaceholder: View {
    let book: AppOpenBook
    @Binding var mode: WindowMode

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(WindowWording.railName(mode))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    mode = mode.closingSheet
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help(WindowWording.closeSheet)
            }
            .padding(.horizontal, 16)
            .frame(height: WindowMetrics.barHeight)
            Divider()
            if mode == .scenes {
                TemporarySceneList(book: book, mode: $mode)
            } else {
                Text(WindowWording.sheetComingLater)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        // Takes the keyboard focus, so the page or panel the sheet covers no longer has it.
        .background(UndoFocusHolder(role: .sheet))
    }
}

// TEMPORARY (#11 scaffolding, until #28's Scenes sheet): open and add scenes.

private struct TemporarySceneList: View {
    let book: AppOpenBook
    @Binding var mode: WindowMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(book.book.scenes) { scene in
                Button(WindowWording.sceneName(scene)) {
                    book.select(scene.id)
                    mode = mode.closingSheet
                }
                .buttonStyle(.link)
            }
            Button(WindowWording.addScene) { book.addScene(after: book.openScene) }
                .disabled(!book.isEditable)
                .padding(12)
        }
    }
}
