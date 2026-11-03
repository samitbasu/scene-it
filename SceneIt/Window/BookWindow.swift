import SceneItCore
import SwiftUI

typealias AppOpenBook = OpenBook<ContinuousClock>

/// The window over an open book (PLAN §4): toolbar, rail, page, right panel and status bar,
/// with the rail's sheets over the page and the panel.
struct BookWindow: View {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    let formatting: PageFormatting
    @Binding var mode: WindowMode

    var body: some View {
        VStack(spacing: 0) {
            ReadOnlyBanner(book: book, store: store, preferences: preferences)
            HStack(spacing: 0) {
                IconRail(book: book, mode: $mode)
                Divider()
                ZStack {
                    // Under a sheet, nothing here can keep focus or be reached with Tab.
                    HStack(spacing: 0) {
                        EditorArea(book: book, formatting: formatting)
                        Divider()
                        RightPanel(book: book, preferences: preferences)
                    }
                    .disabled(mode.isSheet)
                    .accessibilityHidden(mode.isSheet)
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
