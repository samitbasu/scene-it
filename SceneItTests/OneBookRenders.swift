import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// Renders ADR 0038's menus, start screen and alerts into `close-to-start/` under the render
/// folder, for look reviews: the File menu (its real items and states, drawn by `MenuStandIn`
/// under a stand-in menu bar, since an open menu can't be captured) with a book open and on the
/// start screen; the start screen after a close; and, as the app's own `NSAlert`, the refusal,
/// new-book refusal, lost-book and several-books alerts (the first book open, and none). They
/// drive the app's own menus and window, so they run with the other tests of the app's store.
extension OneAtATime.BookStoreIntegrationTests {
    @Test(.enabled(if: renderFolder != nil)) func oneBookPerProcessRenders() async throws {
        let output = try #require(renderFolder).appending(path: "close-to-start", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withTemporaryFolder { folder in
            let books = BookController.shared
            try #require(books.store.isChoosing, "precondition: the start screen")

            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            #expect(await books.store.create(at: url) == .created)
            await eventually { OneBookRenders.fileMenu().items.first?.isEnabled == false }
            try OneBookRenders.write(OneBookRenders.fileMenu(), name: "file-menu-book-open", to: output)

            #expect(await books.store.closeBook() == .left)
            await eventually { OneBookRenders.fileMenu().items.first?.isEnabled == true }
            try OneBookRenders.write(OneBookRenders.fileMenu(), name: "file-menu-start-screen", to: output)

            // A controller of its own, so Recent Books holds only this render's books.
            let closing = BookController(role: .testHost)
            let start = folder.appending(path: "Start", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: start, withIntermediateDirectories: false)
            for name in ["The Lighthouse", "My Novel"] {
                let book = start.appending(path: "\(name).sceneit", directoryHint: .isDirectory)
                #expect(await closing.store.create(at: book) == .created)
                #expect(await closing.store.closeBook() == .left)
            }
            try OneBookRenders.write(
                try await WindowRenders.render(MainWindow(books: closing)), name: "start-screen-after-close",
                to: output)

            let other = folder.appending(path: "Other Book.sceneit")
            let untitled = folder.appending(path: "Untitled.sceneit")
            let lost = try OneBookRenders.loadError(in: folder, named: "My Novel")
            let copy = folder.appending(path: "My Novel (my edits).sceneit")
            let others = ["The Lighthouse", "Other Book"].map { folder.appending(path: "\($0).sceneit") }
            let alerts: [(String, Notice)] = [
                ("refusal", OneBookWording.refusal(of: [other], whileOpen: url)),
                ("create-refusal", OneBookWording.createRefusal(of: untitled, whileOpen: url)),
                ("book-lost", OneBookWording.bookLost(lost, myVersion: copy)),
                ("several-books", OneBookWording.severalBooks(open: url, addedToRecents: others)),
                ("several-books-none-open", OneBookWording.severalBooks(open: nil, addedToRecents: others)),
            ]
            for (name, notice) in alerts {
                try OneBookRenders.write(try await OneBookRenders.alert(notice), name: name, to: output)
            }
            expectNoQuestions()
        }
    }
}

@MainActor
enum OneBookRenders {
    static let barHeight: CGFloat = 24
    static let margin: CGFloat = 40

    /// A copy of the app's File menu, updated as AppKit does before showing it, with only its
    /// visible items.
    static func fileMenu() -> NSMenu {
        let file = menuItem(titled: StoreWording.newBookMenuItem, in: NSApp.mainMenu)?.menu ?? NSMenu()
        file.delegate?.menuNeedsUpdate?(file)
        file.update()
        let copy = NSMenu(title: file.title)
        copy.autoenablesItems = false
        for item in file.items where !item.isHidden {
            let duplicate = item.copy() as! NSMenuItem
            copy.addItem(duplicate)
        }
        return copy
    }

    /// The menu open under a stand-in menu bar holding the app's real menu titles.
    static func draw(_ menu: NSMenu, scale: Int) -> NSBitmapImageRep {
        let font = NSFont.menuBarFont(ofSize: 0)
        let titles = (NSApp.mainMenu?.items ?? []).map(\.title)
        let menuSize = menu.size
        let size = CGSize(
            width: max(menuSize.width + 2 * margin, 640), height: barHeight + menuSize.height + margin)
        let rep = WindowRenders.blankBitmap(width: Int(size.width) * scale, height: Int(size.height) * scale)
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.86, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(white: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight).fill()
        var x: CGFloat = 16
        var fileX = x
        for (index, title) in titles.enumerated() {
            let isApp = index == 0
            let isFile = title == menu.title
            let text = NSAttributedString(
                string: title,
                attributes: [.font: isApp ? NSFont.boldSystemFont(ofSize: font.pointSize) : font])
            let width = text.size().width + 18
            if isFile {
                fileX = x
                NSColor.black.withAlphaComponent(0.1).setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: x, y: size.height - barHeight + 2, width: width, height: barHeight - 4),
                    xRadius: 5, yRadius: 5
                ).fill()
            }
            text.draw(
                at: NSPoint(x: x + 9, y: size.height - barHeight + (barHeight - text.size().height) / 2))
            x += width
        }
        MenuStandIn.draw(
            menu,
            in: NSRect(
                x: fileX, y: size.height - barHeight - menuSize.height - 4, width: menuSize.width,
                height: menuSize.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func write(_ menu: NSMenu, name: String, to folder: URL) throws {
        try write(
            WindowRenders.Renders(
                single: draw(menu, scale: 1), double: draw(menu, scale: 2), triple: draw(menu, scale: 3)),
            name: name, to: folder)
    }

    /// The alert `AlertPrompts` would show for `notice`, laid out in an offscreen window.
    static func alert(_ notice: Notice) async throws -> WindowRenders.Renders {
        let alert = AlertPrompts.alert(title: notice.title, message: notice.message, buttons: [])
        alert.layout()
        let window = alert.window
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        return WindowRenders.Renders(
            single: WindowRenders.bitmap(of: frameView, scale: 1),
            double: WindowRenders.bitmap(of: frameView, scale: 2),
            triple: WindowRenders.bitmap(of: frameView, scale: 3))
    }

    static func write(_ renders: WindowRenders.Renders, name: String, to folder: URL) throws {
        try WindowRenders.png(renders.single).write(to: folder.appending(path: "\(name)@1x.png"))
        try WindowRenders.png(renders.double).write(to: folder.appending(path: "\(name)@2x.png"))
    }

    /// The error opening a package whose `book.md` is a folder, with a backup listed.
    static func loadError(in folder: URL, named name: String) throws -> LoadError {
        let lost = folder.appending(path: "lost", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lost, withIntermediateDirectories: false)
        let url = lost.appending(path: "\(name).sceneit", directoryHint: .isDirectory)
        _ = try BookPackage.create(at: url, title: name)
        let book = url.appending(path: "book.md")
        try FileManager.default.copyItem(at: book, to: url.appending(path: "book.md.bak1"))
        try FileManager.default.removeItem(at: book)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: false)
        do {
            _ = try BookPackage.open(at: url)
        } catch {
            return error
        }
        Issue.record("precondition: the package doesn't open")
        throw CancellationError()
    }
}
