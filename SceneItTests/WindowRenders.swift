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
nonisolated private var renderFolder: URL? {
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

    @Test func candidates() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { book in
            var looks: [(String, String, WindowLook)] = []
            let base = WindowLook.recommended
            for (name, icons) in [
                ("a1-rail-document", WindowLook.RailIcons.document), ("a2-rail-cabinet", .cabinet),
                ("a3-rail-text", .text),
            ] {
                var look = base
                look.railIcons = icons
                for item in WindowMode.allCases {
                    #expect(
                        NSImage(systemSymbolName: look.symbol(for: item), accessibilityDescription: nil)
                            != nil, "\(look.symbol(for: item))")
                }
                looks.append(
                    (
                        name,
                        "Rail icons: "
                            + WindowMode.allCases.map { look.symbol(for: $0) }.joined(separator: " / "), look
                    ))
            }
            for (name, placement, label) in [
                ("b1-title-strip-Title", WindowLook.TitlePlacement.strip, WindowLook.TitleLabel.title),
                ("b1-title-strip-SceneTitle", .strip, .sceneTitle),
                ("b2-title-controlbar-Title", .controlBar, .title),
                ("b3-title-heading-Title", .heading, .title),
                ("b3-title-heading-SceneTitle", .heading, .sceneTitle),
            ] {
                var look = base
                look.titlePlacement = placement
                look.titleLabel = label
                looks.append((name, "Title field: \(placement), label “\(label.text)”", look))
            }
            for (name, toolbar) in [
                ("c1-toolbar-native", WindowLook.Toolbar.native), ("c2-toolbar-custom", .custom),
            ] {
                var look = base
                look.toolbar = toolbar
                looks.append((name, "Toolbar: \(toolbar)", look))
            }
            for (name, tabs, status) in [
                ("d1-tabs-text-status-plain", WindowLook.PanelTabs.text, WindowLook.StatusBar.plain),
                ("d2-tabs-segmented-status-divided", .segmented, .divided),
            ] {
                var look = base
                look.panelTabs = tabs
                look.statusBar = status
                looks.append((name, "Panel tabs: \(tabs); status bar: \(status)", look))
            }
            var rails: [NSBitmapImageRep] = []
            for (name, caption, look) in looks {
                let reps = try await Self.render(BookWindow(book: book), look: look)
                try Self.write(reps, name: name, caption: caption, to: output)
                if name.hasPrefix("a") { rails.append(reps.double) }
            }
            try Self.writeRailCloseup(rails, to: output)

            let recommended = WindowLook.recommended
            try Self.write(
                try await Self.render(BookWindow(book: book, mode: .scenes), look: recommended),
                name: "s4-state-scenes-sheet", caption: "State: Scenes sheet open (temporary list until #28)",
                to: output)
            book.setRightPanel(.closed)
            try Self.write(
                try await Self.render(BookWindow(book: book), look: recommended),
                name: "s5-state-panel-collapsed", caption: "State: right panel collapsed", to: output)
            book.setRightPanel(.open)
            let boneyardScene = try #require(book.book.boneyard.first?.id)
            book.select(boneyardScene)
            try Self.write(
                try await Self.render(BookWindow(book: book), look: recommended),
                name: "s2-state-boneyard-scene", caption: "State: a Boneyard scene open", to: output)
            book.select(nil)
            try Self.write(
                try await Self.render(BookWindow(book: book), look: recommended),
                name: "s3-state-no-scene", caption: "State: no scene open", to: output)
        }
        try await withStartState { books in
            try Self.write(
                try await Self.render(MainWindow(books: books), look: .recommended),
                name: "s1-state-start", caption: "State: no book open", to: output)
        }
    }

    // MARK: Sample books

    private func withSampleBook(_ body: (AppOpenBook) async throws -> Void) async throws {
        try await withTemporaryFolder { folder in
            let store = BookController(role: .testHost).store
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            #expect(await store.closeBook() == .left)
            try BookCoding.encode(Self.sampleBook()).write(
                to: url.appending(path: "book.json"), options: .atomic)
            #expect(await store.open(url) == .opened)
            let book = try #require(store.current)
            try await body(book)
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
    static func render(_ view: some View, look: WindowLook) async throws -> Renders {
        let controller = NSHostingController(rootView: view.environment(\.windowLook, look))
        controller.sizingOptions = []
        controller.sceneBridgingOptions = look.toolbar == .native ? [.toolbars, .title] : []
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if look.toolbar == .custom { style.insert(.fullSizeContentView) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize), styleMask: style, backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        if look.toolbar == .custom { window.titlebarAppearsTransparent = true }
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
        try png(try composite(renders.single, caption: caption)).write(
            to: folder.appending(path: "\(name)-vs-mockup.png"))
    }

    static func png(_ rep: NSBitmapImageRep) throws -> Data {
        try #require(rep.representation(using: .png, properties: [:]))
    }

    /// The candidate at 1× on the left and the mockup on the right, each under a caption.
    static func composite(_ candidate: NSBitmapImageRep, caption: String) throws -> NSBitmapImageRep {
        let mockup = try #require(NSImage(contentsOf: mockup))
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
        NSAttributedString(string: "Mockup: 01-main-window.png", attributes: attributes)
            .draw(at: NSPoint(x: windowSize.width + gap + 8, y: size.height - 30))
        candidate.draw(in: NSRect(origin: .zero, size: windowSize))
        mockup.draw(in: NSRect(origin: NSPoint(x: windowSize.width + gap, y: 0), size: windowSize))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The top of each rail candidate at 2×, side by side with the mockup's rail scaled to match.
    static func writeRailCloseup(_ rails: [NSBitmapImageRep], to folder: URL) throws {
        let mockup = try #require(NSImage(contentsOf: mockup))
        let crop = CGSize(width: 120, height: 300)
        let gap: CGFloat = 16
        let header: CGFloat = 30
        let columns = CGFloat(rails.count + 1)
        let size = CGSize(
            width: columns * crop.width * 2 + (columns - 1) * gap, height: crop.height * 2 + header)
        let rep = blankBitmap(width: Int(size.width), height: Int(size.height))
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.8, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium)
        ]
        let target = { (column: Int) in
            NSRect(
                x: CGFloat(column) * (crop.width * 2 + gap), y: 0, width: crop.width * 2,
                height: crop.height * 2)
        }
        for (column, rail) in rails.enumerated() {
            let image = NSImage(size: rail.size)
            image.addRepresentation(rail)
            image.draw(
                in: target(column),
                from: NSRect(x: 0, y: rail.size.height - crop.height, width: crop.width, height: crop.height),
                operation: .copy, fraction: 1)
            NSAttributedString(string: "a\(column + 1)", attributes: attributes)
                .draw(at: NSPoint(x: target(column).minX + 6, y: size.height - 24))
        }
        mockup.draw(
            in: target(rails.count),
            from: NSRect(x: 0, y: windowSize.height - crop.height, width: crop.width, height: crop.height),
            operation: .copy, fraction: 1)
        NSAttributedString(string: "mockup", attributes: attributes)
            .draw(at: NSPoint(x: target(rails.count).minX + 6, y: size.height - 24))
        NSGraphicsContext.restoreGraphicsState()
        try png(rep).write(to: folder.appending(path: "a0-rail-closeup-2x.png"))
    }
}
