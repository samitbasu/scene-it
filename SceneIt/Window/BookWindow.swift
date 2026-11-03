import SceneItCore
import SwiftUI

typealias AppOpenBook = OpenBook<ContinuousClock>

/// The window over an open book (PLAN §4): toolbar, rail, page, right panel and status bar,
/// with the rail's sheets over the page and the panel, and File a Copy's dialog and toast.
struct BookWindow: View {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    let formatting: PageFormatting
    @Binding var mode: WindowMode
    let filing: FilingFlow

    init(
        book: AppOpenBook, store: AppBookStore, preferences: AppPreferences, formatting: PageFormatting,
        mode: Binding<WindowMode>, filing: FilingFlow = FilingFlow()
    ) {
        self.book = book
        self.store = store
        self.preferences = preferences
        self.formatting = formatting
        _mode = mode
        self.filing = filing
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
        .modifier(FilingToastOverlay(flow: filing))
        .toolbar { WindowToolbar(book: book, filing: filing) }
        .navigationTitle(book.book.title)
        .focusedSceneValue(\.windowMode, $mode)
        .focusedSceneValue(\.filingFlow, book.isEditable ? filing : nil)
        .sheet(isPresented: isFiling) {
            FileACopyDialog(
                draft: draft, isFiling: filing.isFiling, cancel: { filing.cancel() },
                confirm: { Task { await filing.confirm(in: store) } })
        }
    }

    private var isFiling: Binding<Bool> {
        Binding(get: { filing.draft != nil }, set: { if !$0 { filing.cancel() } })
    }

    private var draft: Binding<FilingDraft> {
        Binding(
            get: { filing.draft ?? FilingDraft(today: CalendarDay(.now, in: .current)) },
            set: { filing.draft = $0 })
    }
}

extension FocusedValues {
    /// The focused window's mode, for the View menu.
    @Entry var windowMode: Binding<WindowMode>?
}
