import SceneItCore
import SwiftUI

/// A zone of the Scenes sheet that takes dropped scenes. AppKit tells it as a drag enters,
/// moves over and leaves it, which `SceneDropState` turns into the slot and the tray's light;
/// the drop itself goes through `ScenesActions.drop(on:)`.
struct SceneDropDelegate: DropDelegate {
    let zone: DropZone
    let actions: ScenesActions

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.sceneDrag]) && actions.accepts(zone)
    }

    func dropEntered(info: DropInfo) {
        actions.enter(zone)
    }

    func dropExited(info: DropInfo) {
        actions.exit(zone)
    }

    /// A move, not a copy: the pointer shows no + badge.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: actions.accepts(zone) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        actions.drop(on: zone)
    }
}

extension View {
    /// Lets the writer drag `drag` from this view, while the book takes edits.
    @ViewBuilder
    func sceneDragSource(_ drag: SceneDrag, actions: ScenesActions, editability: Editability) -> some View {
        switch editability {
        case .editable: onDrag { actions.beginDrag(drag) }
        case .commentsOnly, .readOnly: self
        }
    }

    /// Makes this view the drop zone `zone`, while the book takes edits.
    @ViewBuilder
    func sceneDropZone(_ zone: DropZone, actions: ScenesActions, editability: Editability) -> some View {
        switch editability {
        case .editable: onDrop(of: [.sceneDrag], delegate: SceneDropDelegate(zone: zone, actions: actions))
        case .commentsOnly, .readOnly: self
        }
    }
}

/// The dashed slot that shows where a dragged scene will land (PLAN §7.3's "Restore here").
struct DropSlot: View {
    let drag: SceneDrag
    let view: ScenesView

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WindowMetrics.Scenes.cornerRadius)
        let color =
            switch WindowMetrics.Scenes.look.slot {
            case .accent: Color.accentColor
            case .neutral: Color.secondary
            }
        Text(ScenesWording.slot(for: drag))
            .font(.system(size: WindowMetrics.Scenes.titleSize, weight: .medium))
            .foregroundStyle(color)
            .frame(
                maxWidth: .infinity, minHeight: WindowMetrics.Scenes.slotHeight(view), maxHeight: .infinity
            )
            .background(color.opacity(WindowMetrics.Scenes.slotFillOpacity), in: shape)
            .overlay(shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
    }
}
