import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Renders the main window offscreen to PNGs, so the owner can judge its look beside the
/// mockup (CLAUDE.md: aesthetic choices are the owner's). Off unless `SCENEIT_RENDER_DIR`
/// names an output folder; through xcodebuild, set `TEST_RUNNER_SCENEIT_RENDER_DIR`.
///
/// Each render draws our own window's views into a bitmap (`cacheDisplay`); nothing reads the
/// screen. Books are created in a temporary folder through a test-host `BookController`.
nonisolated var renderFolder: URL? {
    ProcessInfo.processInfo.environment["SCENEIT_RENDER_DIR"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
    }
}

@Suite(.serialized, .enabled(if: renderFolder != nil), .timeLimit(.minutes(5)))
struct WindowRenders {

    static let windowSize = CGSize(width: 1440, height: 900)

    static var mockup: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "novel-app-build-bundle/mockups/screenshots/01-main-window.png")
    }

    /// The window as it ships, in each of its states.
    @Test func window() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            let window = { (mode: WindowMode) in
                BookWindow(book: book, store: store, preferences: preferences, mode: .constant(mode))
            }
            try Self.write(
                try await Self.render(window(.page)), name: "final-window", caption: "Scene It: a scene open",
                to: output)
            try Self.write(
                try await Self.render(window(.scenes)), name: "final-scenes-sheet",
                caption: "Scenes sheet open (temporary list until #28)", to: output)
            preferences.setRightPanel(.closed)
            try Self.write(
                try await Self.render(window(.page)), name: "final-panel-collapsed",
                caption: "Right panel collapsed", to: output)
            preferences.setRightPanel(.open)
            book.select(try #require(book.book.boneyard.first?.id))
            try Self.write(
                try await Self.render(window(.page)), name: "final-boneyard-scene",
                caption: "A Boneyard scene open", to: output)
            book.select(nil)
            try Self.write(
                try await Self.render(window(.page)), name: "final-no-scene", caption: "No scene open",
                to: output)
        }
        try await withStartState { books in
            try Self.write(
                try await Self.render(MainWindow(books: books)), name: "final-start", caption: "No book open",
                to: output)
        }
    }

    // MARK: Sample books

    func withSampleBook(_ body: (AppBookStore, AppOpenBook, AppPreferences) async throws -> Void) async throws
    {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            #expect(await store.closeBook() == .left)
            try BookFormat.serialize(Self.sampleBook()).write(
                to: url.appending(path: "book.md"), options: .atomic)
            #expect(await store.open(url) == .opened)
            let book = try #require(store.current)
            try await body(store, book, books.preferences)
            #expect(await store.closeBook() == .left)
        }
    }

    private func withStartState(_ body: (BookController) async throws -> Void) async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            for name in ["The Lighthouse", "My Novel"] {
                let url = folder.appending(path: "\(name).sceneit", directoryHint: .isDirectory)
                #expect(await books.store.create(at: url) == .created)
                #expect(await books.store.closeBook() == .left)
            }
            try await body(books)
        }
    }

    static func sampleBook() -> Book {
        var ids = IDGenerator<SystemRandomNumberGenerator>.system
        let now = Timestamp(.now, in: .current)
        let ferry: [Paragraph] = [
            [
                Run(
                    "The ferry left at dawn, and Mara watched the harbor lights go out one by one behind her."
                )
            ],
            [
                Run(
                    "She had packed in the dark, by feel, the way she used to as a girl when the house was "
                        + "asleep and leaving still seemed like a game.")
            ],
            [
                Run(
                    "Halfway across, the engine coughed and the deckhand swore at it in a language she half "
                        + "remembered. He found the letter under the bench an hour later, but by then she was "
                        + "already ashore.")
            ],
        ]
        let titles = [
            "The ferry", "Arrival", "The letter", "Market day", "The lighthouse keeper", "A cold supper",
            "Storm warning", "What the tide left", "Inventory", "The second letter", "Harbor master",
            "Night crossing", "The island school", "Debts", "Fog", "The chapel bell", "Confession", "Salt",
            "The mainland call", "Low water", "Lanterns", "The return", "Ashore", "Morning",
        ]
        let filler: [Paragraph] = [
            [Run("Nobody met her at the landing, which she had half expected and wholly dreaded.")],
            [Run("The radio crackled twice and then gave up entirely, and the fog came in behind it.")],
        ]
        let scenes = titles.enumerated().map { index, title in
            BookScene(
                id: ids.sceneID(), modified: now, title: SceneTitle(title), body: index == 0 ? ferry : filler)
        }
        let boneyard = ["The brother", "A second ending"].map {
            BookScene(id: ids.sceneID(), modified: now, title: SceneTitle($0), body: filler)
        }
        return Book(title: "My Novel", scenes: scenes, boneyard: boneyard)
    }

    // MARK: Rendering

    struct Renders {
        let single: NSBitmapImageRep
        let double: NSBitmapImageRep
    }

    /// The whole window, title bar and toolbar included, at 1× and 2×.
    static func render(_ view: some View) async throws -> Renders {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: windowSize), display: false)
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        try await Task.sleep(for: .milliseconds(800))
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(200))
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        return Renders(single: bitmap(of: frameView, scale: 1), double: bitmap(of: frameView, scale: 2))
    }

    static func bitmap(of view: NSView, scale: Int) -> NSBitmapImageRep {
        let bounds = view.bounds
        let rep = blankBitmap(width: Int(bounds.width) * scale, height: Int(bounds.height) * scale)
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    static func blankBitmap(width: Int, height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)!
    }

    // MARK: Output

    static func write(_ renders: Renders, name: String, caption: String, to folder: URL) throws {
        try png(renders.single).write(to: folder.appending(path: "\(name)@1x.png"))
        try png(renders.double).write(to: folder.appending(path: "\(name)@2x.png"))
        let mockup = try #require(NSImage(contentsOf: mockup))
        try png(try composite(renders.single, caption: caption, beside: mockup, "Mockup: 01-main-window.png"))
            .write(to: folder.appending(path: "\(name)-vs-mockup.png"))
    }

    static func png(_ rep: NSBitmapImageRep) throws -> Data {
        try #require(rep.representation(using: .png, properties: [:]))
    }

    /// The candidate at 1× on the left and `other` on the right, each under a caption.
    static func composite(
        _ candidate: NSBitmapImageRep, caption: String, beside other: NSImage, _ otherCaption: String
    ) throws -> NSBitmapImageRep {
        let gap: CGFloat = 24
        let header: CGFloat = 40
        let size = CGSize(width: windowSize.width * 2 + gap, height: windowSize.height + header)
        let rep = blankBitmap(width: Int(size.width), height: Int(size.height))
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.8, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium)
        ]
        NSAttributedString(string: caption, attributes: attributes).draw(
            at: NSPoint(x: 8, y: size.height - 30))
        NSAttributedString(string: otherCaption, attributes: attributes)
            .draw(at: NSPoint(x: windowSize.width + gap + 8, y: size.height - 30))
        candidate.draw(in: NSRect(origin: .zero, size: windowSize))
        other.draw(in: NSRect(origin: NSPoint(x: windowSize.width + gap, y: 0), size: windowSize))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
