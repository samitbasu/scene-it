import SceneItCore
import SwiftUI

/// The right panel (PLAN §4.4): one tab per `RightPanelTab`, collapsible to a thin strip. Its
/// open state and tab are app preferences (ADR 0022), so changing them never edits the book.
/// The Comments, Notes and Tags tabs' contents arrive with #19, #20 and #25.
struct RightPanel: View {
    let book: AppOpenBook
    let preferences: AppPreferences
    @Environment(\.errorsLook) private var look

    var body: some View {
        let errorCount = book.book.errorCount
        let tabs = RightPanelTab.shown(errorCount: errorCount, look.tabVisibility)
        let selected = RightPanelTab.selected(preferences.rightPanelTab, among: tabs)
        switch preferences.rightPanel {
        case .open:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    PanelTabs(
                        tabs: tabs, selected: selected,
                        badge: look.tabVisibility == .whenPresent ? errorCount : 0, preferences: preferences)
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
                if selected == .errors {
                    ErrorsTab(book: book)
                } else {
                    Spacer()
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
