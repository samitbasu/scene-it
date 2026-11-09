import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Export as SceneIt's chooser (#79), chosen by default while the owner was away: the shipped
/// dialog (A) and two alternatives (B, C) drawn from the same flow, for the owner to compare. Each
/// shows the sample book's 24 story scenes with four unticked, so the count and a mixed state
/// show. A and B are sheets over the window at 1× and 2× beside mockup 14 (File a Copy, the
/// pattern A follows), with the sheet alone at 3×. C is a save-panel accessory: the system panel
/// around it can't be drawn offscreen, so it's the accessory alone, at the width the panel gives it.
extension WindowRenders {
    private static func chooserFlow(_ book: AppOpenBook) -> ExportFlow {
        let flow = ExportFlow(book: book, destination: { .nowhere })
        flow.begin()
        let ids = book.book.scenes.map(\.id)
        flow.click(ids[3], .single)
        flow.click(ids[6], .extendingRange)
        return flow
    }

    @Test func exportChooser() async throws {
        let output = try #require(renderFolder).appending(path: "export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            @MainActor func window(_ export: ExportFlow) -> BookWindow {
                BookWindow(
                    book: book, store: store, preferences: preferences,
                    formatting: EditorFormatting(preferences: preferences), mode: .constant(.page),
                    export: export)
            }

            let shipped = Self.chooserFlow(book)
            try #require(shipped.choice?.ticked.count == 20, "precondition: four scenes unticked")
            let (renders, close) = try await Self.withWindow(window(shipped)) { window in
                let sheet = try #require(window.attachedSheet, "precondition: the chooser is a sheet")
                return (
                    try Self.withSheet(window, sheet),
                    Self.bitmap(of: try #require(sheet.contentView?.superview), scale: 3)
                )
            }
            #expect(shipped.choice != nil, "the chooser stayed up while it was drawn")
            shipped.cancel()
            try Self.write(
                renders, name: "export-a-sheet", caption: "A (shipped): a sheet like File a Copy's, buttons",
                to: output, beside: Self.fileACopyMockup)
            try Self.png(close).write(to: output.appending(path: "export-a-sheet-dialog@3x.png"))

            let listed = Self.chooserFlow(book)
            try await Self.renderAsSheet(
                ListChooserCandidate(flow: listed),
                over: window(ExportFlow(book: book, destination: { .nowhere })),
                name: "export-b-list", caption: "B: a bordered list with an All scenes checkbox", to: output)

            let accessory = Self.chooserFlow(book)
            let view = PanelAccessoryCandidate(flow: accessory)
                .frame(width: 520)
                .background(Color(nsColor: .windowBackgroundColor))
            for scale in [1, 2] {
                let rep = try await Self.withHostedView(view) { Self.bitmap(of: $0, scale: scale) }
                try Self.png(rep).write(to: output.appending(path: "export-c-panel-accessory@\(scale)x.png"))
            }
        }
    }

    /// `sheet` attached to the window `base` draws, at 1×, 2× and 3×, as the shipped chooser is.
    private static func renderAsSheet(
        _ sheet: some View, over base: some View, name: String, caption: String, to output: URL
    ) async throws {
        let controller = NSHostingController(rootView: sheet)
        controller.sizingOptions = .preferredContentSize
        let sheetWindow = NSWindow(contentViewController: controller)
        let attach = { (window: NSWindow) in window.beginSheet(sheetWindow) }
        let (renders, close) = try await withWindow(base, preparing: attach) { window in
            let attached = try #require(window.attachedSheet, "precondition: the candidate is a sheet")
            return (
                try withSheet(window, attached),
                bitmap(of: try #require(attached.contentView?.superview), scale: 3)
            )
        }
        try write(renders, name: name + "-sheet", caption: caption, to: output, beside: fileACopyMockup)
        try png(close).write(to: output.appending(path: "\(name)-sheet-dialog@3x.png"))
    }

    /// `view` alone in an offscreen window sized to it, laid out and drawn, for `capture`.
    static func withHostedView<T>(_ view: some View, capture: (NSView) throws -> T) async throws -> T {
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: hosting.fittingSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        try await Task.sleep(for: .milliseconds(800))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        return try capture(hosting)
    }
}

/// Candidate B: a bordered list with alternating rows, headed by an All scenes checkbox that
/// shows a mixed state, the count beside the buttons.
private struct ListChooserCandidate: View {
    let flow: ExportFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ExportWording.dialogTitle).font(.headline)
            Text(ExportWording.dialogExplanation)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let choice = flow.choice {
                List {
                    Toggle("All scenes", sources: rowBindings(choice), isOn: \.self)
                        .toggleStyle(.checkbox)
                        .fontWeight(.semibold)
                    ForEach(choice.rows) { row in
                        Toggle(ExportWording.row(row), isOn: ticked(row.id, choice)).toggleStyle(.checkbox)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 260)
                HStack {
                    Text(ExportWording.tickedCount(choice.ticked.count, of: choice.rows.count))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(ExportWording.cancel) {}
                    Button(ExportWording.confirm) {}
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func rowBindings(_ choice: ExportChoice) -> [Binding<Bool>] {
        choice.rows.map { ticked($0.id, choice) }
    }

    private func ticked(_ scene: SceneID, _ choice: ExportChoice) -> Binding<Bool> {
        Binding(get: { choice.isTicked(scene) }, set: { _ in flow.click(scene, .single) })
    }
}

/// Candidate C: no sheet; the scenes as the save panel's accessory view, under its name and
/// folder fields, so the chooser and the panel are one step.
private struct PanelAccessoryCandidate: View {
    let flow: ExportFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let choice = flow.choice {
                HStack {
                    Text("Scenes to export:").fontWeight(.semibold)
                    Spacer()
                    Text(ExportWording.tickedCount(choice.ticked.count, of: choice.rows.count))
                        .foregroundStyle(.secondary)
                }
                ExportSceneList(flow: flow, choice: choice)
                    .frame(height: 180)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                HStack {
                    Button(ExportWording.selectAll) {}
                    Button(ExportWording.selectNone) {}
                    Spacer()
                    Text(ExportWording.rangeHint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(16)
    }
}
