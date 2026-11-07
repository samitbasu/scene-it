import AppKit
import SwiftUI
import Testing

@testable import SceneIt

/// The Errors tab's fix field (#127) as it was, a SwiftUI `TextField`, above the
/// `AdmittingTextField` that replaces it, with the same long line at the panel's width, then both
/// empty, showing their placeholder, into a
/// `menus/` subfolder as `fix-field`.
extension WindowRenders {
    @Test func fixField() async throws {
        let output = try #require(renderFolder).appending(path: "menus", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let line = "- c1 | mauve | 2026-10-31T20:40:00-07:00 | c12-18 | \"letter\" | Too early?"
        let view = VStack(alignment: .leading, spacing: 10) {
            Text("Before: SwiftUI TextField").font(.caption)
            TextField("Fix", text: .constant(line), axis: .vertical)
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            Text("After: AdmittingTextField").font(.caption)
            FixTextField(text: .constant(line))
            Text("Empty, before and after").font(.caption)
            TextField("Fix", text: .constant(""), axis: .vertical)
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            FixTextField(text: .constant(""))
            Spacer()
        }
        .padding(22)
        .frame(width: WindowMetrics.panelWidth, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        let window = await hostOffscreen(view, size: CGSize(width: WindowMetrics.panelWidth, height: 360)) {
            window in subviewTree(of: window.contentView).contains { $0 is AdmittingTextField }
        }
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        try Self.png(Self.bitmap(of: content, scale: 1)).write(to: output.appending(path: "fix-field@1x.png"))
        try Self.png(Self.bitmap(of: content, scale: 2)).write(to: output.appending(path: "fix-field@2x.png"))
    }
}
