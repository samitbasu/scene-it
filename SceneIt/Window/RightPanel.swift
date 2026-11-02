import SceneItCore
import SwiftUI

/// The right panel (PLAN §4.4): one tab per `RightPanelTab`, collapsible to a thin strip. Its
/// open state and tab are app preferences (ADR 0022), so changing them never edits the book.
/// The tabs' contents arrive with #19, #20 and #25.
struct RightPanel: View {
    let preferences: AppPreferences

    var body: some View {
        switch preferences.rightPanel {
        case .open:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    PanelTabs(preferences: preferences)
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
                Spacer()
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

/// Text tabs with an underline under the selected one.
private struct PanelTabs: View {
    let preferences: AppPreferences

    var body: some View {
        HStack(spacing: 18) {
            ForEach(RightPanelTab.allCases, id: \.self) { tab in
                let selected = tab == preferences.rightPanelTab
                Button {
                    preferences.showRightPanelTab(tab)
                } label: {
                    Text(WindowWording.tab(tab))
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? .primary : .secondary)
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
