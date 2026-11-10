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
        struct Render {
            var variant: ToolbarVariant
            var file: WindowToolbar.FileACopyLook
            var justify: WindowToolbar.Justify = .leading
            var width: CGFloat = ToolbarVariantRenders.size.width
            var name: String
            var label: String
        }
        let d: [Render] = [
            Render(variant: .iconOnly, file: .labeledBlue, name: "D1-labeled-blue", label: "D1. File a copy… labeled, blue"),
            Render(variant: .iconOnly, file: .iconBlue, name: "D2-icon-blue", label: "D2. File a copy icon-only, blue"),
            Render(
                variant: .iconOnly, file: .iconInPill, name: "D3-icon-in-pill",
                label: "D3. File a copy icon-only, in the Print/Export pill"),
            Render(
                variant: .iconOnly, file: .iconOwnPill, name: "D4-icon-own-pill",
                label: "D4. File a copy icon-only, its own pill"),
        ]
        let c = Render(variant: .groupsZoomMenu, file: .labeledBlue, name: "C", label: "C. Labeled Print/Export, labeled blue File a copy…")
        func right(_ r: Render, width: CGFloat? = nil) -> Render {
            var r = r
            r.justify = .trailingSpacer
            r.name = "R-" + r.name.split(separator: "-").first!
            r.label = "R-" + r.label
            if let width {
                r.width = width
                r.name += "-\(Int(width))"
                r.label += " (narrowest window, \(Int(width)) pt)"
            }
            return r
        }
        let rightJustified = [right(c)] + d.map { right($0) } + [right(c, width: WindowMetrics.minimumSize.width), right(d[0], width: WindowMetrics.minimumSize.width)]
        var primary = right(c)
        primary.justify = .primaryAction
        primary.name = "probes/R-C-primary-action-placement"
        let renders = d + rightJustified + [primary]
        var images: [String: CGImage] = [:]
        try FileManager.default.createDirectory(
            at: output.appending(path: "probes", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try await WindowRenders().withSampleBook(sample) { store, book, preferences in
            preferences.setZoom(Zoom(clamping: 1.5))
            for render in renders {
                for look in [Look.light, .dark] {
                    WindowToolbar.variant = render.variant
                    WindowToolbar.gap = .doubleFixed
                    WindowToolbar.fileACopyLook = render.file
                    WindowToolbar.justify = render.justify
                    let size = CGSize(width: render.width, height: Self.size.height)
                    let view = BookWindow(
                        book: book, store: store, preferences: preferences,
                        formatting: EditorFormatting(preferences: preferences), mode: .constant(.page))
                    let image = try await WindowRenders.withWindow(view, in: ActiveWindow.self, size: size) {
                        window in
                        window.appearance = NSAppearance(named: look == .dark ? .darkAqua : .aqua)
                        try await Task.sleep(for: .milliseconds(600))
                    } capture: { window in
                        let full = try #require(Self.composited(window))
                        #expect(full.width == Int(size.width) * 2)
                        let barHeight = window.frame.height - window.contentLayoutRect.maxY
                        return try #require(
                            full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: Int(barHeight * 2) + 16)))
                    }
                    let name = look == .dark ? "\(render.name)-dark" : render.name
                    images[name] = image
                    try Self.png(image).write(to: output.appending(path: "\(name).png"))
                }
            }
            WindowToolbar.variant = .current
            WindowToolbar.gap = .fixed
            WindowToolbar.fileACopyLook = .labeledBlue
            WindowToolbar.justify = .leading
        }
        for (set, file) in [(d, "file-a-copy-options"), (rightJustified, "right-justified-options")] {
            try Self.png(try Self.stack(set.map { ($0.label, try #require(images[$0.name])) }))
                .write(to: output.appending(path: "\(file).png"))
            try Self.png(try Self.stack(set.map { ("\($0.label) (dark)", try #require(images["\($0.name)-dark"])) }))
                .write(to: output.appending(path: "\(file)-dark.png"))
        }
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
