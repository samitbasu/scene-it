import SceneItCore
import SwiftUI

/// The Boneyard along the bottom of the Scenes sheet (PLAN §7.3, mockup 07): "Boneyard (n)", the
/// hint, and a tile for each cut scene, most recently cut first. A card dragged over it lights it
/// red, and dropped there it's cut.
struct BoneyardTray: View {
    let book: AppOpenBook
    let model: ScenesSheetModel
    let actions: ScenesActions
    let editability: Editability

    var body: some View {
        let boneyard = book.book.boneyard
        VStack(alignment: .leading, spacing: WindowMetrics.Scenes.Boneyard.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(BoneyardWording.title)
                    .font(.system(size: WindowMetrics.Scenes.Boneyard.titleSize, weight: .semibold))
                Text(BoneyardWording.count(boneyard.count))
                    .font(.system(size: WindowMetrics.Scenes.Boneyard.titleSize))
                    .foregroundStyle(.secondary)
                Text(BoneyardWording.hint)
                    .font(.system(size: WindowMetrics.Scenes.metaSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 4)
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: WindowMetrics.Scenes.Boneyard.tileGap) {
                    ForEach(boneyard, id: \.id) { scene in
                        BoneyardTile(
                            scene: scene, words: book.wordCounts[scene.id],
                            isOpen: scene.id == book.openScene ? .open : .notOpen,
                            dragging: model.drop.drag == .tile(scene.id) ? .dragged : .still,
                            actions: actions,
                            editability: editability)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: WindowMetrics.Scenes.Boneyard.tileHeight)
        }
        .padding(.horizontal, WindowMetrics.Scenes.gridPadding)
        .padding(.vertical, WindowMetrics.Scenes.Boneyard.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            model.drop.isOverTray ? WindowMetrics.Scenes.Boneyard.litFill : WindowMetrics.Scenes.Boneyard.fill
        )
        .overlay { if model.drop.isOverTray { litBorder } }
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .sceneDropZone(.tray, actions: actions, editability: editability)
    }

    @ViewBuilder private var litBorder: some View {
        switch WindowMetrics.Scenes.look.trayLight {
        case .fillAndOutline:
            Rectangle().strokeBorder(WindowMetrics.Scenes.Boneyard.litLine, lineWidth: 2)
        case .fillAndDashedOutline:
            RoundedRectangle(cornerRadius: WindowMetrics.Scenes.cornerRadius)
                .strokeBorder(
                    WindowMetrics.Scenes.Boneyard.litLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                )
                .padding(4)
        }
    }
}

/// Whether a card or tile is the one being dragged.
enum Dragging {
    case dragged, still
}

/// A cut scene in the tray (mockup 07): the drag handle, the title and the words, in a dashed
/// outline, then ↩. A click opens the scene; its menu restores it or deletes it for good.
private struct BoneyardTile: View {
    let scene: BookScene
    let words: WordCount
    let isOpen: SceneCardContent.IsOpen
    let dragging: Dragging
    let actions: ScenesActions
    let editability: Editability
    @State private var hovering = Hovering.away

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WindowMetrics.Scenes.Boneyard.tileCornerRadius)
        HStack(spacing: 6) {
            if editability == .editable { DragGrip().accessibilityHidden(true) }
            Text(WindowWording.sceneName(scene))
                .font(.system(size: WindowMetrics.Scenes.Boneyard.tileTitleSize, weight: .semibold))
                .foregroundStyle(scene.title.text.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(BoneyardWording.words(words))
                .font(.system(size: WindowMetrics.Scenes.Boneyard.tileWordsSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            if showsRestore { restoreButton }
        }
        .padding(.horizontal, 10)
        .frame(
            width: WindowMetrics.Scenes.Boneyard.tileWidth, height: WindowMetrics.Scenes.Boneyard.tileHeight
        )
        .background(
            isOpen == .open ? WindowMetrics.Scenes.openFill : WindowMetrics.Scenes.Boneyard.tileFill,
            in: shape
        )
        .overlay(border(shape))
        .contentShape(shape)
        .opacity(dragging == .dragged ? WindowMetrics.Scenes.draggedOpacity : 1)
        .onTapGesture { actions.open(scene.id) }
        .onHover { hovering = $0 ? .hovering : .away }
        .help(BoneyardWording.openHelp)
        .sceneDragSource(.tile(scene.id), actions: actions, editability: editability)
        .contextMenu {
            Button(BoneyardWording.open) { actions.open(scene.id) }
            if editability == .editable {
                Button(BoneyardWording.restore) { actions.restoreToEnd(scene.id) }
                Divider()
                Button(BoneyardWording.deletePermanently) {
                    Task { await actions.deletePermanently(scene.id) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions.open(scene.id) }
    }

    private var showsRestore: Bool {
        guard editability == .editable else { return false }
        switch WindowMetrics.Scenes.look.restoreButton {
        case .always: return true
        case .onHover: return hovering == .hovering
        }
    }

    private var restoreButton: some View {
        Button {
            actions.restoreToEnd(scene.id)
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: WindowMetrics.Scenes.Boneyard.tileWordsSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(BoneyardWording.restoreHelp)
        .accessibilityLabel(BoneyardWording.restore)
    }

    @ViewBuilder private func border(_ shape: RoundedRectangle) -> some View {
        switch isOpen {
        case .open:
            shape.strokeBorder(Color.accentColor, lineWidth: WindowMetrics.Scenes.openBorder)
        case .notOpen:
            shape.strokeBorder(
                hovering == .hovering
                    ? WindowMetrics.Scenes.hoverLine : WindowMetrics.Scenes.Boneyard.tileLine,
                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}
