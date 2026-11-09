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
    @State private var export: ExportFlow
    @State private var undo: UndoRouter
    @State private var pageFocus: PageFocus
    @State private var editors: SceneEditors
    @State private var search: SearchSheetModel
    @State private var chrome: WindowChrome
    @State private var keys: WindowKeys

    init(
        book: AppOpenBook, store: AppBookStore, preferences: AppPreferences, formatting: EditorFormatting,
        mode: Binding<WindowMode>, filing: FilingFlow? = nil, export: ExportFlow? = nil,
        search: SearchSheetModel? = nil, chrome: WindowChrome? = nil
    ) {
        self.book = book
        self.store = store
        self.preferences = preferences
        self.formatting = formatting
        _mode = mode
        let filing = filing ?? FilingFlow(book: book)
        _filing = State(initialValue: filing)
        let export = export ?? ExportFlow(book: book, destination: { .nowhere })
        _export = State(initialValue: export)
        _search = State(initialValue: search ?? SearchSheetModel(book: book))
        _undo = State(initialValue: UndoRouter(book: book))
        let focus = PageFocus()
        _pageFocus = State(initialValue: focus)
        let chrome = chrome ?? WindowChrome()
        _chrome = State(initialValue: chrome)
        let keys = WindowKeys(chrome: chrome, filing: filing, export: export, page: focus, mode: mode)
        _keys = State(initialValue: keys)
        _editors = State(
            initialValue: SceneEditors(
                book: book, preferences: preferences, formatting: formatting, focus: focus, keys: keys))
    }

    var body: some View {
        VStack(spacing: 0) {
            ReadOnlyBanner(book: book, store: store, preferences: preferences)
            HStack(spacing: 0) {
                if chrome.shows(.rail) {
                    IconRail(book: book, mode: $mode)
                    Divider()
                }
                ZStack {
                    // Under a sheet, nothing here can keep focus or be reached with Tab.
                    HStack(spacing: 0) {
                        EditorArea(
                            book: book, preferences: preferences, formatting: formatting, focus: pageFocus,
                            editors: editors)
                        if chrome.shows(.rightPanel) {
                            Divider()
                            RightPanel(
                                book: book, preferences: preferences, formatting: formatting,
                                editors: editors,
                                search: search, mode: $mode)
                        }
                    }
                    .overlay { FocusModeHint(chrome: chrome) }
                    .disabled(mode.isSheet)
                    .accessibilityHidden(mode.isSheet)
                    if mode == .search {
                        SearchSheet(model: search, mode: $mode)
                    } else if mode.isSheet {
                        SheetPlaceholder(book: book, mode: $mode)
                    }
                }
            }
            if chrome.shows(.statusBar) {
                Divider()
                StatusBar(book: book)
            }
        }
        .background(.background)
        .modifier(FilingToastOverlay(flow: filing))
        .background(UndoRouterWindow(router: undo))
        .environment(undo)
        .environment(\.pageFocus, pageFocus)
        .environment(\.windowKeys, keys)
        .focusedSceneValue(\.undoRouter, undo)
        .background(FocusModeToolbar(chrome: chrome))
        .background(WindowEscapeFallback(keys: keys))
        .onChange(of: mode, initial: true) { old, new in
            undo.mode = mode
            if mode == .search { search.refresh() } else { search.close() }
            // On the next turn, once the page the sheet covered is enabled again and can take it.
            if old.isSheet, !new.isSheet, chrome.focusMode == .on {
                DispatchQueue.main.async { [pageFocus, chrome, mode = $mode] in
                    guard !mode.wrappedValue.isSheet, chrome.focusMode == .on, !pageFocus.holdsFocus else {
                        return
                    }
                    pageFocus.focusBody()
                }
            }
        }
        .onChange(of: chrome.focusMode) {
            // Whatever had the focus in the chrome is gone; the page takes it, its caret where it was.
            if chrome.focusMode == .on, !pageFocus.holdsFocus { pageFocus.focusBody() }
        }
        .onAppear {
            search.opener = SearchOpener(
                book: book, preferences: preferences, editors: editors, focus: pageFocus, mode: $mode)
        }
        .toolbar {
            WindowToolbar(book: book, store: store, preferences: preferences, undo: undo, filing: filing)
        }
        .navigationTitle(book.book.title)
        .focusedSceneValue(\.windowMode, $mode)
        .focusedSceneValue(\.filingFlow, filing)
        .focusedSceneValue(\.exportFlow, export)
        .background(WindowReporter { [filing] in filing.window = $0 })
        .sheet(item: dialog) { _ in
            FileACopyDialog(
                draft: filing.draftBinding, stage: filing.stage, cancel: { filing.cancel() },
                confirm: { Task { await filing.confirm(in: store) } }
            )
            .background(EscapeKey(keys: keys))
            .background(WindowEscapeFallback(keys: keys, commands: .keyAndCancelOperation))
            .interactiveDismissDisabled()
            .environment(undo)
            .environment(\.windowKeys, keys)
            .focusedSceneValue(\.undoRouter, undo)
        }
        .sheet(isPresented: chooser) {
            ExportChooserDialog(flow: export) { Task { await export.confirm(in: store) } }
                .background(EscapeKey(keys: keys))
                .background(WindowEscapeFallback(keys: keys, commands: .keyAndCancelOperation))
                .environment(\.windowKeys, keys)
        }
    }

    /// Export as SceneIt's chooser is up exactly while it has a choice, which holds nothing the
    /// writer would mind losing: if SwiftUI ends the sheet itself, the export is cancelled.
    private var chooser: Binding<Bool> {
        Binding(get: { export.choice != nil }, set: { if !$0 { export.cancel() } })
    }

    /// The dialog is up exactly while there's a draft: only the model's own actions (Cancel,
    /// Esc through `WindowKeys`, a copy filed) end one, so nothing SwiftUI writes here can drop
    /// what the writer typed. If SwiftUI ever ends the sheet itself, File a Copy… shows the same
    /// draft again (`FilingFlow.begin`).
    private var dialog: Binding<FilingPresentation?> {
        Binding(get: { filing.draft == nil ? nil : filing.presentation }, set: { _ in })
    }
}

extension FocusedValues {
    /// The focused window's mode, for the View menu.
    @Entry var windowMode: Binding<WindowMode>?
}
