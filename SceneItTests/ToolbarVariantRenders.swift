import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// The toolbar look review: each `ToolbarVariant` in the real window, cropped to the title bar,
/// at 2×. Off unless `SCENEIT_RENDER_DIR` names an output folder.
@Suite(.serialized, .enabled(if: renderFolder != nil), .timeLimit(.minutes(10)))
@MainActor
struct ToolbarVariantRenders {
    static let size = CGSize(width: 1280, height: 800)

    enum Look { case light, dark }

    @Test func toolbars() async throws {
        let output = try #require(renderFolder).appending(path: "toolbar", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var sample = WindowRenders.sampleBook()
        sample.title = "My Bookus"
        sample.scenes[0].title = SceneTitle("Into the thing.")
        let renders: [(ToolbarVariant, Look, WindowToolbar.Gap, String)] = [
            (.current, .light, .fixed, "A-current"), (.groups, .light, .doubleFixed, "B-groups"),
            (.groupsZoomMenu, .light, .doubleFixed, "C-groups-zoom-menu"),
            (.iconOnly, .light, .doubleFixed, "D-icon-only"),
            (.current, .dark, .fixed, "A-current-dark"), (.groups, .dark, .doubleFixed, "B-groups-dark"),
            (.groupsZoomMenu, .dark, .doubleFixed, "C-groups-zoom-menu-dark"),
            (.iconOnly, .dark, .doubleFixed, "D-icon-only-dark"),
            (.groups, .light, .fixed, "probes/B-single-fixed-spacers"),
            (.groups, .light, .flexible, "probes/B-flexible-spacers"),
            (.probeItemGroup, .light, .fixed, "probes/item-groups-no-spacer"),
            (.probeAdjacentItems, .light, .fixed, "probes/adjacent-items-one-spacer"),
            (.probeNavigationStyle, .light, .fixed, "probes/control-group-navigation-style"),
            (.probePaletteStyle, .light, .fixed, "probes/control-group-palette-style"),
            (.probeHStack, .light, .fixed, "probes/hstack-in-items"),
        ]
        try FileManager.default.createDirectory(
            at: output.appending(path: "probes", directoryHint: .isDirectory), withIntermediateDirectories: true)
        var images: [String: CGImage] = [:]
        try await WindowRenders().withSampleBook(sample) { store, book, preferences in
            preferences.setZoom(Zoom(clamping: 1.5))
            for (variant, look, gap, name) in renders {
                WindowToolbar.variant = variant
                WindowToolbar.gap = gap
                let view = BookWindow(
                    book: book, store: store, preferences: preferences,
                    formatting: EditorFormatting(preferences: preferences), mode: .constant(.page))
                let image = try await WindowRenders.withWindow(view, in: ActiveWindow.self, size: Self.size) {
                    window in
                    window.appearance = NSAppearance(named: look == .dark ? .darkAqua : .aqua)
                    try await Task.sleep(for: .milliseconds(600))
                } capture: { window in
                    let full = try #require(Self.composited(window))
                    #expect(full.width == Int(Self.size.width) * 2)
                    let barHeight = window.frame.height - window.contentLayoutRect.maxY
                    return try #require(
                        full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: Int(barHeight * 2) + 16)))
                }
                images[name] = image
                try Self.png(image).write(to: output.appending(path: "\(name).png"))
            }
            WindowToolbar.variant = .current
            WindowToolbar.gap = .fixed
        }
        let light: [(String, String)] = [
            ("A. Current", "A-current"), ("B. Real groups with gaps", "B-groups"),
            ("C. B with a zoom pull-down", "C-groups-zoom-menu"),
            ("D. C with icon-only Print and Export to Word", "D-icon-only"),
        ]
        try Self.png(try Self.stack(light.map { ($0.0, try #require(images[$0.1])) }))
            .write(to: output.appending(path: "toolbar-options.png"))
        let dark: [(String, String)] = [
            ("A. Current (dark)", "A-current-dark"), ("B. Real groups with gaps (dark)", "B-groups-dark"),
            ("C. B with a zoom pull-down (dark)", "C-groups-zoom-menu-dark"),
            ("D. C with icon-only Print and Export to Word (dark)", "D-icon-only-dark"),
        ]
        try Self.png(try Self.stack(dark.map { ($0.0, try #require(images[$0.1])) }))
            .write(to: output.appending(path: "toolbar-options-dark.png"))
    }

    /// Says it's key and main, so the toolbar draws as in the window the writer is using,
    /// without activating the app.
    final class ActiveWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        // AppKit draws the frame's controls from these private hooks, which follow the app's
        // activation; answering for them avoids activating the test host.
        @objc func _hasActiveAppearance() -> Bool { true }
        @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
        @objc func _hasKeyAppearance() -> Bool { true }
        @objc func _hasMainAppearance() -> Bool { true }
    }

    /// Our own window as the window server composites it, Liquid Glass included, which
    /// `cacheDisplay` can't draw. Reads only this window (`optionIncludingWindow`).
    /// `CGWindowListCreateImage` is unavailable to Swift since macOS 15, so it's looked up.
    static func composited(_ window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let ignoreFramingBestResolution: UInt32 = 1 << 0 | 1 << 3
        return create(.null, includingWindow, UInt32(window.windowNumber), ignoreFramingBestResolution)?
            .takeRetainedValue()
    }

    static func png(_ image: CGImage) throws -> Data {
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// The images one under another at their own pixel size, each under its label.
    static func stack(_ items: [(String, CGImage)]) throws -> CGImage {
        let header = 64
        let gap = 24
        let width = items.map(\.1.width).max() ?? 0
        let height = items.reduce(0) { $0 + header + $1.1.height + gap }
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.82, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        var top = height
        for (label, image) in items {
            NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.black,
                ]
            ).draw(at: NSPoint(x: 20, y: top - header + 12))
            top -= header + image.height
            context.draw(image, in: CGRect(x: 0, y: top, width: image.width, height: image.height))
            top -= gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(context.makeImage())
    }
}
