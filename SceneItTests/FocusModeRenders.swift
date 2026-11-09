import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// Focus mode as the owner picked it (#21), beside normal mode. It's drawn from the app's own
/// window, whose toolbar is the `Window` scene's, so the render shows the toolbar hidden as the
/// app hides it.
extension OneAtATime.BookStoreIntegrationTests {
    @Test(.enabled(if: renderFolder != nil)) func focusModeRenders() async throws {
        let output = try #require(renderFolder).appending(path: "focus-mode", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            #expect(await books.store.closeBook() == .left)
            try BookFormat.serialize(WindowRenders.sampleBook()).write(
                to: url.appending(path: "book.md"), options: .atomic)
            #expect(await books.store.open(url) == .opened)
            let book = try #require(books.store.current)
            let scene = try #require(book.openScene)
            book.replaceBody(
                of: scene, with: Array(repeating: WindowRenders.formattedBody, count: 2).flatMap(\.self))

            let window = try #require(books.mainWindow, "precondition: the app's main window")
            let frame = window.frame
            defer { window.setFrame(frame, display: true) }
            window.setFrame(NSRect(origin: frame.origin, size: WindowRenders.windowSize), display: true)
            @MainActor func desk() -> DeskView? {
                subviewTree(of: window.contentView).lazy.compactMap { $0 as? DeskView }.first {
                    $0.keys != nil
                }
            }
            await eventually { desk() != nil && window.toolbar?.isVisible == true }
            let chrome = try #require(desk()?.keys?.chrome)
            let page = try #require(WindowRenders.page(in: window))
            #expect(window.makeFirstResponder(page))
            page.setSelectedRange(NSRange(location: 40, length: 0))

            let normal = try await Self.capture(window)
            try Self.write(normal, name: "normal", to: output)

            chrome.set(.on)
            await eventually { window.toolbar?.isVisible == false }
            let focused = try await Self.capture(window)
            try Self.write(focused, name: "focus", to: output)
            try WindowRenders.png(
                try WindowRenders.composite(
                    focused.single, caption: "Focus mode: the hint as it begins (it fades after 3 s)",
                    beside: Self.image(normal.single), "Normal mode")
            ).write(to: output.appending(path: "focus-vs-normal.png"))

            chrome.set(.off)
            books.preferences.setRightPanel(.closed)
            defer { books.preferences.setRightPanel(.open) }
            await eventually { window.toolbar?.isVisible == true }
            try Self.write(try await Self.capture(window), name: "normal-panel-collapsed", to: output)
            chrome.set(.on)
            await eventually { window.toolbar?.isVisible == false }
            try Self.write(try await Self.capture(window), name: "focus-from-panel-collapsed", to: output)
            chrome.set(.off)

            #expect(await books.store.closeBook() == .left)
        }
    }

    /// The window, title bar and all, at 1× and 2×, once SwiftUI has laid out the change.
    @MainActor
    private static func capture(_ window: NSWindow) async throws -> WindowRenders.Renders {
        try await Task.sleep(for: .milliseconds(500))
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        return WindowRenders.Renders(
            single: WindowRenders.bitmap(of: frameView, scale: 1),
            double: WindowRenders.bitmap(of: frameView, scale: 2),
            triple: WindowRenders.bitmap(of: frameView, scale: 3))
    }

    private static func write(_ renders: WindowRenders.Renders, name: String, to folder: URL) throws {
        try WindowRenders.png(renders.single).write(to: folder.appending(path: "\(name)@1x.png"))
        try WindowRenders.png(renders.double).write(to: folder.appending(path: "\(name)@2x.png"))
    }

    private static func image(_ rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
