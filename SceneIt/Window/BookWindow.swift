import SceneItCore
import SwiftUI

typealias AppOpenBook = OpenBook<ContinuousClock>

/// The window over an open book (PLAN §4): toolbar, rail, page, right panel and status bar,
/// with the rail's sheets over the page and the panel.
struct BookWindow: View {
    let book: AppOpenBook
    @State private var mode: WindowMode
    @Environment(\.windowLook) private var look

    init(book: AppOpenBook, mode: WindowMode = .page) {
        self.book = book
        _mode = State(initialValue: mode)
    }

    var body: some View {
        VStack(spacing: 0) {
            if look.toolbar == .custom {
                CustomToolbar(book: book)
                Divider()
            }
            HStack(spacing: 0) {
                IconRail(book: book, mode: $mode)
                Divider()
                ZStack {
                    HStack(spacing: 0) {
                        EditorArea(book: book)
                        Divider()
                        RightPanel(book: book)
                    }
                    if mode.isSheet {
                        SheetPlaceholder(book: book, mode: $mode)
                    }
                }
            }
            Divider()
            StatusBar(book: book)
        }
        .ignoresSafeArea(.container, edges: look.toolbar == .custom ? .top : [])
        .background(.background)
        .modifier(NativeToolbar(book: book))
        .navigationTitle(book.book.title)
        .focusedSceneValue(\.windowMode, $mode)
    }
}

extension FocusedValues {
    /// The focused window's mode, for the View menu.
    @Entry var windowMode: Binding<WindowMode>?
}
