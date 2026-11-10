import SceneItCore
import SwiftUI

/// The window toolbar (PLAN §4.1). Undo and Redo go where `UndoRouter` says; Print and Export to
/// Word go through the window's own flows, as the File menu does. File a copy… is only for a book
/// open for editing and not being closed (`FilingFlow.canBegin`).
struct WindowToolbar: ToolbarContent {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    let undo: UndoRouter
    let filing: FilingFlow
    let printing: PrintFlow
    let wordExport: WordExportFlow

    /// Render-only switch for the toolbar look review (branch `toolbar-variants`, never main).
    static var variant: ToolbarVariant = .current

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Breadcrumb(book: book)
                .padding(.horizontal, 8)
        }
        .sharedBackgroundVisibility(.hidden)
        switch Self.variant {
        case .current: current
        case .groups: groups(zoom: .stepper, output: .titleAndIcon)
        case .groupsZoomMenu: groups(zoom: .menu, output: .titleAndIcon)
        case .iconOnly: groups(zoom: .menu, output: .iconOnly)
        case .probeItemGroup: probeItemGroup
        case .probeAdjacentItems: probeAdjacentItems
        case .probeNavigationStyle: probeStyle(.navigation)
        case .probePaletteStyle: probeStyle(.palette)
        case .probeHStack: probeHStack
        }
    }

    @ToolbarContentBuilder private var current: some ToolbarContent {
        ToolbarItem {
            ControlGroup {
                undoButton
                redoButton
            }
            .disabled(!book.isEditable)
        }
        ToolbarItem {
            ControlGroup {
                zoomButton(.zoomOut, systemImage: "minus")
                zoomLabel
                zoomButton(.zoomIn, systemImage: "plus")
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem { printButton.labelStyle(.titleAndIcon) }
        ToolbarItem { exportButton.labelStyle(.titleAndIcon) }
        if book.document.kind != .filedCopy {
            fileACopy
        }
    }

    enum ZoomControl { case stepper, menu }
    enum OutputLabels { case titleAndIcon, iconOnly }

    enum Gap { case fixed, doubleFixed, flexible }
    static var gap: Gap = .fixed

    @ToolbarContentBuilder private var groupGap: some ToolbarContent {
        switch Self.gap {
        case .fixed: ToolbarSpacer(.fixed)
        case .doubleFixed:
            ToolbarSpacer(.fixed)
            ToolbarSpacer(.fixed)
        case .flexible: ToolbarSpacer(.flexible)
        }
    }

    /// Each run of adjacent items shares one glass capsule; `ToolbarSpacer` ends a run.
    @ToolbarContentBuilder private func groups(zoom: ZoomControl, output: OutputLabels) -> some ToolbarContent {
        ToolbarItemGroup {
            undoButton
            redoButton
        }
        groupGap
        switch zoom {
        case .stepper:
            ToolbarItemGroup {
                zoomButton(.zoomOut, systemImage: "minus")
                zoomLabel
                zoomButton(.zoomIn, systemImage: "plus")
            }
        case .menu:
            ToolbarItem { zoomMenu }
        }
        groupGap
        switch output {
        case .titleAndIcon:
            ToolbarItemGroup {
                printButton.labelStyle(.titleAndIcon)
                exportButton.labelStyle(.titleAndIcon)
            }
        case .iconOnly:
            ToolbarItemGroup {
                printButton.labelStyle(.iconOnly).help(WindowWording.print)
                exportButton.labelStyle(.iconOnly).help(WindowWording.exportToWord)
            }
        }
        if book.document.kind != .filedCopy {
            fileACopy
        }
    }

    @ToolbarContentBuilder private var probeItemGroup: some ToolbarContent {
        ToolbarItemGroup {
            undoButton
            redoButton
        }
        ToolbarItemGroup {
            zoomButton(.zoomOut, systemImage: "minus")
            zoomLabel
            zoomButton(.zoomIn, systemImage: "plus")
        }
    }

    @ToolbarContentBuilder private var probeAdjacentItems: some ToolbarContent {
        ToolbarItem { undoButton }
        ToolbarItem { redoButton }
        ToolbarSpacer(.fixed)
        ToolbarItem { zoomButton(.zoomOut, systemImage: "minus") }
        ToolbarItem { zoomLabel }
        ToolbarItem { zoomButton(.zoomIn, systemImage: "plus") }
    }

    @ToolbarContentBuilder private func probeStyle(_ style: some ControlGroupStyle) -> some ToolbarContent {
        ToolbarItem {
            ControlGroup {
                undoButton
                redoButton
            }
            .controlGroupStyle(style)
        }
        ToolbarItem {
            ControlGroup {
                zoomButton(.zoomOut, systemImage: "minus")
                zoomLabel
                zoomButton(.zoomIn, systemImage: "plus")
            }
            .controlGroupStyle(style)
        }
    }

    @ToolbarContentBuilder private var probeHStack: some ToolbarContent {
        ToolbarItem {
            HStack {
                undoButton
                redoButton
            }
        }
        ToolbarItem {
            HStack {
                zoomButton(.zoomOut, systemImage: "minus")
                zoomLabel
                zoomButton(.zoomIn, systemImage: "plus")
            }
        }
    }

    private var undoButton: some View {
        Button(WindowWording.undo, systemImage: "arrow.uturn.backward") { undo.undo() }
            .help(undo.state.undo ?? WindowWording.undo)
            .disabled(undo.state.undo == nil || !book.isEditable)
    }

    private var redoButton: some View {
        Button(WindowWording.redo, systemImage: "arrow.uturn.forward") { undo.redo() }
            .help(undo.state.redo ?? WindowWording.redo)
            .disabled(undo.state.redo == nil || !book.isEditable)
    }

    private var zoomLabel: some View {
        Text(WindowWording.zoom(preferences.zoom))
            .monospacedDigit()
            .frame(minWidth: 44)
    }

    private var zoomMenu: some View {
        Menu {
            ForEach(Zoom.steps, id: \.self) { step in
                Button(WindowWording.zoom(step)) { preferences.setZoom(step) }
            }
            Divider()
            ForEach(ZoomStep.allCases, id: \.self) { step in
                Button(WindowWording.zoomStep(step)) { preferences.zoom(step) }
                    .disabled(!preferences.canZoom(step))
            }
            Button(WindowWording.actualSize) { preferences.setZoom(.standard) }
        } label: {
            Text(WindowWording.zoom(preferences.zoom))
                .monospacedDigit()
        }
        .help("Zoom")
    }

    private var printButton: some View {
        Button(WindowWording.print, systemImage: "printer") { printing.begin() }
            .disabled(!printing.canBegin)
    }

    private var exportButton: some View {
        Button(WindowWording.exportToWord, systemImage: "doc.text") {
            Task { await wordExport.begin() }
        }
        .disabled(!wordExport.canBegin)
    }

    /// Hidden over a filed copy (PLAN §4.1).
    @ToolbarContentBuilder private var fileACopy: some ToolbarContent {
        groupGap
        ToolbarItem {
            Button(WindowWording.fileACopy, systemImage: "archivebox") { filing.begin() }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(!filing.canBegin(in: store))
        }
    }

    private func zoomButton(_ step: ZoomStep, systemImage: String) -> some View {
        Button(WindowWording.zoomStep(step), systemImage: systemImage) { preferences.zoom(step) }
            .help(WindowWording.zoomStep(step))
            .disabled(!preferences.canZoom(step))
    }
}

/// "My Novel › 1. The ferry": the book in bold, then where the open scene is.
private struct Breadcrumb: View {
    let book: AppOpenBook

    var body: some View {
        let parts = WindowWording.breadcrumb(bookTitle: book.book.title, book.location)
        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("›").foregroundStyle(.secondary)
                }
                Text(part)
                    .fontWeight(index == 0 ? .semibold : .regular)
                    .foregroundStyle(index == 0 ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
    }
}

enum ToolbarVariant: CaseIterable {
    case current, groups, groupsZoomMenu, iconOnly
    case probeItemGroup, probeAdjacentItems, probeNavigationStyle, probePaletteStyle, probeHStack
}
