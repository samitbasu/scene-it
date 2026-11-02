import SceneItCore
import SwiftUI

/// The status bar (PLAN §4.5): where the open scene is and the word counts, then the save state.
struct StatusBar: View {
    let book: AppOpenBook

    var body: some View {
        let location = book.location
        let parts = WindowWording.statusParts(
            location, sceneWords: location.scene.map { book.wordCounts[$0.id] } ?? .zero,
            bookWords: book.manuscriptWordCount)
        HStack(spacing: 14) {
            ForEach(parts, id: \.self) { Text($0) }
            Spacer()
            Text(StoreWording.status(book.status))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: WindowMetrics.statusBarHeight)
    }
}
