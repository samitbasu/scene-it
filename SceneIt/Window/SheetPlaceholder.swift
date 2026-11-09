import SceneItCore
import SwiftUI

/// A rail sheet, over the page and the right panel (PLAN §4.2). Empty until #33 (File Cabinet)
/// fills it; × or Esc closes it. Scenes is `ScenesSheet`, Search is `SearchSheet`.
struct SheetPlaceholder: View {
    @Binding var mode: WindowMode
    @Environment(\.windowKeys) private var keys

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
                .help(WindowWording.closeSheet)
            }
            .padding(.horizontal, 16)
            .frame(height: WindowMetrics.barHeight)
            Divider()
            Text(WindowWording.sheetComingLater)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        // Takes the keyboard focus, so the page or panel the sheet covers no longer has it.
        .background(UndoFocusHolder(role: .sheet))
        .background(EscapeKey(keys: keys))
    }
}
