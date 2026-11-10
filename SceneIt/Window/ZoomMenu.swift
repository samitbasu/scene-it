import SceneItCore
import SwiftUI

/// Zoom In, Zoom Out and Actual Size, as the View menu and the toolbar's zoom menu both list them.
struct ZoomStepButtons: View {
    let preferences: AppPreferences
    let keys: ZoomKeys

    var body: some View {
        ForEach(ZoomStep.allCases, id: \.self) { step in
            Button(WindowWording.zoomStep(step)) { preferences.zoom(step) }
                .keyboardShortcut(keys.shortcut(for: step))
                .disabled(!preferences.canZoom(step))
        }
        Button(WindowWording.actualSize) { preferences.setZoom(.standard) }
            .keyboardShortcut(keys.actualSize)
    }
}

/// Whether the buttons carry the zoom shortcuts. Only the View menu's do, so a shortcut is
/// never bound twice.
enum ZoomKeys {
    case bound, unbound

    func shortcut(for step: ZoomStep) -> KeyboardShortcut? {
        guard self == .bound else { return nil }
        return switch step {
        case .zoomIn: KeyboardShortcut("=")
        case .zoomOut: KeyboardShortcut("-")
        }
    }

    var actualSize: KeyboardShortcut? {
        self == .bound ? KeyboardShortcut("0") : nil
    }
}

/// The toolbar's zoom: a pull-down titled with the zoom, listing `Zoom.steps` with the current
/// one ticked, then Zoom In, Zoom Out and Actual Size.
struct ZoomMenu: View {
    let preferences: AppPreferences

    var body: some View {
        Menu {
            ForEach(Zoom.steps, id: \.self) { zoom in
                Toggle(WindowWording.zoom(zoom), isOn: chosen(zoom))
            }
            Divider()
            ZoomStepButtons(preferences: preferences, keys: .unbound)
        } label: {
            Text(WindowWording.zoom(preferences.zoom))
                .monospacedDigit()
        }
        .help(WindowWording.zoomMenu)
        .accessibilityLabel(WindowWording.zoomMenu)
        .accessibilityValue(WindowWording.zoom(preferences.zoom))
    }

    private func chosen(_ zoom: Zoom) -> Binding<Bool> {
        Binding(get: { preferences.zoom.isAt(zoom) }, set: { _ in preferences.setZoom(zoom) })
    }
}
