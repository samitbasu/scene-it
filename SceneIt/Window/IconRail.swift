import SceneItCore
import SwiftUI

/// The left icon rail (PLAN §4.2): Current scene, a divider, then the three sheets.
struct IconRail: View {
    let book: AppOpenBook
    @Binding var mode: WindowMode

    var body: some View {
        VStack(spacing: 6) {
            currentScene
            Divider()
                .frame(width: WindowMetrics.railDividerWidth)
                .padding(.vertical, 4)
            ForEach(WindowMode.allCases.filter(\.isSheet), id: \.self) { sheet in
                RailButton(item: sheet, mode: $mode, badge: nil)
                    .help(WindowWording.railName(sheet))
            }
            Spacer()
        }
        .padding(.top, 8)
        .frame(width: WindowMetrics.railWidth)
    }

    private var currentScene: some View {
        let mark = CurrentSceneMark(book.location)
        let badge: String? =
            switch mark {
            case .badge(let text): text
            case .unavailable: nil
            }
        return RailButton(item: .page, mode: $mode, badge: badge)
            .disabled(mark == .unavailable)
            .help(WindowWording.currentSceneTooltip(book.location))
    }
}

private struct RailButton: View {
    let item: WindowMode
    @Binding var mode: WindowMode
    let badge: String?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let highlighted = mode.highlights(item) && isEnabled
        Button {
            mode = mode.choosing(item)
        } label: {
            Image(systemName: Self.symbol(for: item))
                .font(.system(size: 17))
                .frame(width: WindowMetrics.railButtonSize, height: WindowMetrics.railButtonSize)
                .foregroundStyle(highlighted ? Color.accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: WindowMetrics.railButtonCornerRadius)
                        .fill(highlighted ? Color.accentColor.opacity(0.12) : .clear)
                )
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 2, y: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(WindowWording.railName(item))
    }

    private static func symbol(for item: WindowMode) -> String {
        switch item {
        case .page: "doc.text"
        case .scenes: "square.grid.2x2"
        case .search: "magnifyingglass"
        case .fileCabinet: "archivebox"
        }
    }
}
