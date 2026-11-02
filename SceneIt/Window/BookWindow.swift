import SceneItCore
import SwiftUI

typealias AppOpenBook = OpenBook<ContinuousClock>

/// The window over an open book (PLAN §4): toolbar, rail, page, right panel and status bar,
/// with the rail's sheets over the page and the panel.
struct BookWindow: View {
    let book: AppOpenBook
    let preferences: AppPreferences
    @State private var mode: WindowMode

    init(book: AppOpenBook, preferences: AppPreferences, mode: WindowMode = .page) {
        self.book = book
        self.preferences = preferences
        _mode = State(initialValue: mode)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                IconRail(book: book, mode: $mode)
                Divider()
                ZStack {
                    HStack(spacing: 0) {
                        EditorArea(book: book)
                        Divider()
                        RightPanel(preferences: preferences)
                    }
                    if mode.isSheet {
                        SheetPlaceholder(book: book, mode: $mode)
                    }
                }
            }
            Divider()
            StatusBar(book: book)
        }
        .background(.background)
        .toolbar { WindowToolbar(book: book) }
        .navigationTitle(book.book.title)
        .focusedSceneValue(\.windowMode, $mode)
    }
}

extension FocusedValues {
    /// The focused window's mode, for the View menu.
    @Entry var windowMode: Binding<WindowMode>?
}
