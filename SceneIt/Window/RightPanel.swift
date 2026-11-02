import SceneItCore
import SwiftUI

/// The right panel (PLAN §4.4): Comments | Notes | Tags, collapsible to a thin strip. Its
/// open state and tab are the book's settings, so they're saved with it. The tabs' contents
/// arrive with #19, #20 and #25.
struct RightPanel: View {
    let book: AppOpenBook
    @Environment(\.windowLook) private var look

    var body: some View {
        switch book.book.settings.rightPanelOpen {
        case .open:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    tabs
                    Spacer(minLength: 0)
                    Button {
                        book.setRightPanel(.closed)
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
                    book.setRightPanel(.open)
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

    private var selection: Binding<RightPanelTab> {
        Binding(get: { book.book.settings.rightPanel }, set: { book.showRightPanelTab($0) })
    }

    @ViewBuilder private var tabs: some View {
        switch look.panelTabs {
        case .segmented:
            Picker(selection: selection) {
                ForEach(RightPanelTab.allCases, id: \.self) { Text(WindowWording.tab($0)).tag($0) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case .text:
            HStack(spacing: 18) {
                ForEach(RightPanelTab.allCases, id: \.self) { tab in
                    let selected = tab == selection.wrappedValue
                    Button {
                        selection.wrappedValue = tab
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
}
