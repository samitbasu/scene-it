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

    static let mainWindowMockup = "01-main-window.png"

    static func mockup(_ name: String) -> URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "novel-app-build-bundle/mockups/screenshots/\(name)")
    }

    /// The window as it ships, in each of its states.
    @Test func window() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            let window = { (mode: WindowMode) in
                BookWindow(
                    book: book, store: store, preferences: preferences,
                    formatting: EditorFormatting(preferences: preferences), mode: .constant(mode))
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

    /// A damaged book (#63, #67): the banner while it's read-only, then the Errors tab once
    /// it's editable; and a book saved by a newer version.
    @Test func errorsAndBanner() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withBook(Self.damagedSample()) { store, book, preferences in
            let window = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(.page))
            try Self.write(
                try await Self.render(window), name: "final-banner-repaired",
                caption: "Repaired while opening: read-only, with the banner", to: output)
            preferences.reveal(.errors)
            try Self.write(
                try await Self.render(window), name: "final-errors-tab-read-only",
                caption: "Show Repairs: the Errors tab, read-only", to: output)
            #expect(await store.makeEditable() == .editable)
            try Self.write(
                try await Self.render(window), name: "final-errors-tab",
                caption: "The Errors tab once the book is editable", to: output)
            try Self.write(
                try await Self.render(window) { window in
                    let tabs = subviewTree(of: window.contentView).compactMap { $0 as? UndoFocusView }
                    try #require(tabs.first { $0.focus == .errorsTab }).takeFocus()
                },
                name: "final-errors-focus", caption: "The Errors tab with the focus, after a Delete or Fix",
                to: output)
            preferences.showRightPanelTab(.comments)
        }
        let newer = String(decoding: BookFormat.serialize(Self.sampleBook()), as: UTF8.self)
            .replacingOccurrences(of: "format: 2\n", with: "format: 3\n")
        try await withBook(Data(newer.utf8)) { store, book, preferences in
            try Self.write(
                try await Self.render(
                    BookWindow(
                        book: book, store: store, preferences: preferences,
                        formatting: EditorFormatting(preferences: preferences), mode: .constant(.page))),
                name: "final-banner-newer", caption: "Saved by a newer Scene It: read-only", to: output)
        }
    }

    /// The page editor (#15): formatted text on the page, a scene longer than a page scrolled to
    /// its end, and the find bar (Cmd+F) over the desk.
    @Test func page() async throws {
        let output = try #require(renderFolder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withSampleBook { store, book, preferences in
            let window = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(.page))
            let scene = try #require(book.openScene)
            book.replaceBody(of: scene, with: Self.formattedBody)
            try Self.write(
                try await Self.render(window), name: "page-formatted",
                caption: "The page: Times New Roman 12, double-spaced, 0.5 in first-line indent", to: output)
            try Self.write(
                try await Self.render(window) { window in
                    let page = try #require(Self.page(in: window))
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    page.performFindPanelAction(item)
                },
                name: "page-find-bar", caption: "Cmd+F: the find bar above the desk", to: output)
            book.replaceBody(of: scene, with: Array(repeating: Self.formattedBody, count: 4).flatMap(\.self))
            try Self.write(
                try await Self.render(window) { window in
                    let page = try #require(Self.page(in: window))
                    page.scrollToEndOfDocument(nil)
                },
                name: "page-long-scene-end", caption: "A scene longer than a page, scrolled to its end",
                to: output)
        }
    }

    static func page(in window: NSWindow) -> ManuscriptTextView? {
        func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        return window.contentView.flatMap { views(in: $0).compactMap { $0 as? ManuscriptTextView }.first }
    }

    static let formattedBody: [Paragraph] = [
        [
            Run("The ferry left at dawn, and Mara watched the "),
            Run("harbor lights", styles: [.italic]),
            Run(" go out one by one behind her. She had packed in the dark, by feel, the way she used to "),
            Run("as a girl", styles: [.bold]),
            Run(" when the house was asleep and leaving still seemed like a game."),
        ],
        [
            Run("Halfway across, the engine coughed and the deckhand swore at it in a language she half "),
            Run("remembered", color: .purple),
            Run(". He found the "),
            Run("letter", highlight: .green),
            Run(" under the bench an hour later, but by then she was "),
            Run("already", styles: [.strike]),
            Run(" ashore."),
        ],
        [Run("Nobody met her at the landing, which she had half expected and wholly dreaded.")],
    ]

    // MARK: Sample books

    /// Opens `bytes` as a book's `book.md`; the test host's alerts answer Keep Read-Only.
    private func withBook(
        _ bytes: Data, _ body: (AppBookStore, AppOpenBook, AppPreferences) async throws -> Void
    ) async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            #expect(await store.closeBook() == .left)
            try bytes.write(to: url.appending(path: "book.md"), options: .atomic)
            _ = await store.open(url)
            try await body(store, try #require(store.current), books.preferences)
            #expect(await store.closeBook() == .left)
        }
    }

    /// The sample book with book format §9.2's kinds of damage: an unknown front-matter key, a
    /// stray line, a mistyped palette name, a quote that doesn't match, an emoji, and an
    /// unknown metadata key.
    static func damagedSample() throws -> Data {
        var text = String(decoding: BookFormat.serialize(sampleBook()), as: UTF8.self)
        func replace(_ old: String, _ new: String) throws {
            let range = try #require(text.range(of: old))
            text.replaceSubrange(range, with: new)
        }
        try replace("format: 2\n---\n", "format: 2\ncolour: blue\n---\n\nRemember to back this up!\n")
        try replace("behind her.", "behind her. \u{1F30A}")
        try replace(
            "already ashore.\n",
            "already ashore.\n\n### Comments\n"
                + "- c1 | mauve | 2026-10-31T20:40:00-07:00 | c45-58 | \"harbor lights\" | Too pretty?\n"
                + "- c3 | blue | 2026-10-31T20:41:00-07:00 | c4-9 | \"ferry left\" | Wrong range.\n")
        let letter = try #require(text.range(of: "## The letter\n"))
        let modified = try #require(
            text.range(
                of: #"modified: [^\n]+\n"#, options: .regularExpression,
                range: letter.upperBound..<text.endIndex))
        text.insert(contentsOf: "mood: grim\n", at: modified.upperBound)
        return Data(text.utf8)
    }

    func withSampleBook(
        _ sample: Book = WindowRenders.sampleBook(),
        _ body: (AppBookStore, AppOpenBook, AppPreferences) async throws -> Void
    ) async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            #expect(await store.closeBook() == .left)
            try BookFormat.serialize(sample).write(
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
        let triple: NSBitmapImageRep
    }

    /// The whole window, title bar and toolbar included, at 1× and 2×.
    static func render(
        _ view: some View, in windowType: NSWindow.Type = NSWindow.self,
        preparing prepare: (NSWindow) async throws -> Void = { _ in }
    )
        async throws
        -> Renders
    {
        try await withWindow(view, in: windowType, preparing: prepare) { window in
            let frameView = try #require(window.contentView?.superview)
            return Renders(
                single: bitmap(of: frameView, scale: 1), double: bitmap(of: frameView, scale: 2),
                triple: bitmap(of: frameView, scale: 3))
        }
    }

    /// `view` in an offscreen window of `windowSize`, laid out and drawn, for `capture`.
    static func withWindow<T>(
        _ view: some View, in windowType: NSWindow.Type = NSWindow.self,
        preparing prepare: (NSWindow) async throws -> Void = { _ in }, capture: (NSWindow) throws -> T
    ) async throws -> T {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = windowType.init(
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
        try await prepare(window)
        try await Task.sleep(for: .milliseconds(200))
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        return try capture(window)
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

    static func write(
        _ renders: Renders, name: String, caption: String, to folder: URL,
        beside screenshot: String = mainWindowMockup
    ) throws {
        try png(renders.single).write(to: folder.appending(path: "\(name)@1x.png"))
        try png(renders.double).write(to: folder.appending(path: "\(name)@2x.png"))
        let mockup = try #require(NSImage(contentsOf: mockup(screenshot)))
        try png(try composite(renders.single, caption: caption, beside: mockup, "Mockup: \(screenshot)"))
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
