import SceneItCore
import SwiftUI

/// The status bar (PLAN §4.5): where the open scene is and the word counts, then the save state.
struct StatusBar: View {
    let book: AppOpenBook
    @Environment(\.windowLook) private var look

    var body: some View {
        let parts = WindowWording.statusParts(book: book.book, openScene: book.openScene)
        HStack(spacing: 14) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0, look.statusBar == .divided {
                    Divider().frame(height: 12)
                }
                Text(part)
            }
            Spacer()
            if look.statusBar == .divided {
                Divider().frame(height: 12)
            }
            Text(StoreWording.status(book.status))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: WindowMetrics.statusBarHeight)
    }
}
