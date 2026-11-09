import SceneItCore
import SwiftUI

/// The right panel (PLAN §4.4): one tab per `RightPanelTab`, collapsible to a thin strip. Its
/// open state and tab are app preferences (ADR 0022), so changing them never edits the book.
/// The Tags tab's contents arrive with #20.
struct RightPanel: View {
    let book: AppOpenBook
    let preferences: AppPreferences
    let formatting: EditorFormatting
    let editors: SceneEditors
    @Environment(\.windowKeys) private var keys

    var body: some View {
        let errorCount = book.book.errorCount
        let tabs = RightPanelTab.shown(errorCount: errorCount)
        let selected = RightPanelTab.selected(preferences.rightPanelTab, among: tabs)
        let shown: RightPanelTab? = preferences.rightPanel == .open ? selected : nil
        Group {
            panel(tabs: tabs, selected: selected, errorCount: errorCount)
        }
        // When the last entry goes, the Errors tab with it, the panel goes back to Comments.
        .onChange(of: tabs, initial: true) {
            if !tabs.contains(preferences.rightPanelTab) { preferences.showRightPanelTab(.comments) }
        }
        .onChange(of: shown, initial: true) { keys?.shownPanelTab = shown }
        .onDisappear { keys?.shownPanelTab = nil }
    }

    @ViewBuilder private func panel(tabs: [RightPanelTab], selected: RightPanelTab, errorCount: Int)
        -> some View
    {
        switch preferences.rightPanel {
        case .open:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    PanelTabs(tabs: tabs, selected: selected, badge: errorCount, preferences: preferences)
                    Spacer(minLength: 0)
                    Button {
                        preferences.setRightPanel(.closed)
                    } label: {
                        Image(systemName: "chevron.right.2")
                    }
                    .buttonStyle(.borderless)
                    .help(WindowWording.hidePanel)
                }
                .padding(.horizontal, 12)
                .frame(height: WindowMetrics.barHeight)
                Divider()
                switch selected {
                case .errors: ErrorsTab(book: book)
                case .notes: NotesTab(book: book, formatting: formatting, editors: editors)
                case .comments: CommentsTab(book: book, formatting: formatting, editors: editors)
                case .tags: Spacer()
                }
            }
            .frame(width: WindowMetrics.panelWidth)
        case .closed:
            VStack {
                Button {
                    preferences.setRightPanel(.open)
                } label: {
                    Image(systemName: "chevron.left.2")
                }
                .buttonStyle(.borderless)
                .help(WindowWording.showPanel)
                .frame(height: WindowMetrics.barHeight)
                Spacer()
            }
            .frame(width: WindowMetrics.collapsedPanelWidth)
        }
    }
}

/// Text tabs with an underline under the selected one; the Errors tab may carry a count.
private struct PanelTabs: View {
    let tabs: [RightPanelTab]
    let selected: RightPanelTab
    let badge: Int
    let preferences: AppPreferences

    var body: some View {
        HStack(spacing: tabs.count > 3 ? 14 : 18) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == self.selected
                Button {
                    preferences.showRightPanelTab(tab)
                } label: {
                    HStack(spacing: 4) {
                        Text(WindowWording.tab(tab))
                            .fontWeight(selected ? .semibold : .regular)
                            .foregroundStyle(selected ? .primary : .secondary)
                        if tab == .errors, badge > 0 {
                            Text(ErrorsWording.count(badge))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(Color.orange))
                        }
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) {
                        if selected {
                            Rectangle().fill(Color.accentColor).frame(height: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The open scene's notes under their compact formatting bar (PLAN §8.2).
private struct NotesTab: View {
    let book: AppOpenBook
    let formatting: EditorFormatting
    let editors: SceneEditors
    @Environment(\.windowKeys) private var keys

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FormattingBar(formatting: formatting, part: .notes)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: WindowMetrics.barHeight)
            Divider()
            if let scene = book.location.scene {
                NotesView(book: book, editors: editors, scene: scene.id, notes: scene.notes)
            } else {
                Spacer()
            }
        }
        .onAppear {
            keys?.setPanelFocus(for: .notes) { [editors] in
                let notes = editors.notes.textView
                return notes.window?.makeFirstResponder(notes) ?? false
            }
        }
    }
}
