import SceneItCore
import SwiftUI

typealias AppOpenBook = OpenBook<ContinuousClock>

/// The window over an open book (PLAN §4): toolbar, rail, page, right panel and status bar,
/// with the rail's sheets over the page and the panel, and File a Copy's dialog and toast.
struct BookWindow: View {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    let formatting: EditorFormatting
    @Binding var mode: WindowMode
    @State private var filing: FilingFlow
    @State private var undo: UndoRouter
    @State private var pageFocus: PageFocus
    @State private var editors: SceneEditors
    @State private var search: SearchSheetModel

    init(
        book: AppOpenBook, store: AppBookStore, preferences: AppPreferences, formatting: EditorFormatting,
        mode: Binding<WindowMode>, filing: FilingFlow? = nil, search: SearchSheetModel? = nil
    ) {
        self.book = book
        self.store = store
        self.preferences = preferences
        self.formatting = formatting
        _mode = mode
        _filing = State(initialValue: filing ?? FilingFlow(book: book))
        _search = State(initialValue: search ?? SearchSheetModel(book: book))
        _undo = State(initialValue: UndoRouter(book: book))
        let focus = PageFocus()
        _pageFocus = State(initialValue: focus)
        _editors = State(
            initialValue: SceneEditors(
                book: book, preferences: preferences, formatting: formatting, focus: focus))
    }

    var body: some View {
        VStack(spacing: 0) {
            ReadOnlyBanner(book: book, store: store, preferences: preferences)
            HStack(spacing: 0) {
                IconRail(book: book, mode: $mode)
                Divider()
                ZStack {
                    // Under a sheet, nothing here can keep focus or be reached with Tab.
                    HStack(spacing: 0) {
                        EditorArea(
                            book: book, preferences: preferences, formatting: formatting, focus: pageFocus,
                            editors: editors)
                        Divider()
                        RightPanel(
                            book: book, preferences: preferences, formatting: formatting, editors: editors)
                    }
                    .disabled(mode.isSheet)
                    .accessibilityHidden(mode.isSheet)
                    if mode == .search {
                        SearchSheet(model: search, mode: $mode)
                    } else if mode.isSheet {
                        SheetPlaceholder(book: book, mode: $mode)
                    }
                }
            }
            Divider()
            StatusBar(book: book)
        }
        .background(.background)
        .modifier(FilingToastOverlay(flow: filing))
        .background(UndoRouterWindow(router: undo))
        .environment(undo)
        .environment(\.pageFocus, pageFocus)
        .focusedSceneValue(\.undoRouter, undo)
        .focusedSceneValue(\.sceneEditors, editors)
        .onChange(of: mode, initial: true) {
            undo.mode = mode
            if mode == .search { search.refresh() } else { search.close() }
        }
        .onAppear {
            search.opener = SearchOpener(
                book: book, preferences: preferences, editors: editors, focus: pageFocus, mode: $mode)
        }
        .toolbar { WindowToolbar(book: book, preferences: preferences, undo: undo, filing: filing) }
        .navigationTitle(book.book.title)
        .focusedSceneValue(\.windowMode, $mode)
        .focusedSceneValue(\.filingFlow, book.isEditable ? filing : nil)
        .sheet(isPresented: isDialogUp) {
            FileACopyDialog(
                draft: filing.draftBinding, stage: filing.stage, cancel: { filing.cancel() },
                confirm: { Task { await filing.confirm(in: store) } }
            )
            .environment(undo)
            .focusedSceneValue(\.undoRouter, undo)
        }
    }

    private var isDialogUp: Binding<Bool> {
        Binding(get: { filing.draft != nil }, set: { if !$0 { filing.cancel() } })
    }

}

extension FocusedValues {
    /// The focused window's mode, for the View menu.
    @Entry var windowMode: Binding<WindowMode>?
}
