import AppKit
import SceneItCore
import SceneItTestSupport
import Testing

@testable import SceneIt

/// The Edit menu and the page's context menu without the automatic text changes (#127), each
/// with its Spelling submenu open beside it, in a `menus/` subfolder. An open menu can't be
/// captured, so `MenuStandIn` draws the real menus' shown items.
extension WindowRenders {
    @Test func menus() async throws {
        let output = try #require(renderFolder).appending(path: "menus", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let edit = try #require(NSApp.mainMenu?.items.lazy.compactMap(\.submenu).first { $0.title == "Edit" })
        try write(Self.cascade(edit, opening: "Spelling and Grammar"), to: output, name: "edit-menu")
        try await withPage([scene("One", letterScene)]) { page in
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: page.page.convert(NSPoint(x: 120, y: 120), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: page.window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = try #require(page.page.menu(for: event))
            page.page.willOpenMenu(menu, with: event)
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            try write(
                Self.cascade(menu, opening: "Spelling and Grammar"), to: output, name: "page-context-menu")
        }
    }

    private func write(_ draw: (Int) -> NSBitmapImageRep, to folder: URL, name: String) throws {
        try Self.png(draw(1)).write(to: folder.appending(path: "\(name)@1x.png"))
        try Self.png(draw(2)).write(to: folder.appending(path: "\(name)@2x.png"))
    }

    /// `menu` with the submenu titled `title` open beside its row, on a plain backdrop.
    static func cascade(_ menu: NSMenu, opening title: String) throws -> (Int) -> NSBitmapImageRep {
        let item = try #require(menu.items.first { $0.title == title && !$0.isHidden }, "\(title) shows")
        let submenu = try #require(item.submenu)
        let margin: CGFloat = 30
        let size = menu.size
        let subSize = submenu.size
        let rowTop = try #require(
            MenuStandIn.rows(of: menu, in: NSRect(origin: .zero, size: size)).first { $0.0 === item }?.1.maxY)
        let canvas = CGSize(
            width: margin * 2 + size.width + subSize.width - 4,
            height: margin * 2 + max(size.height, size.height - rowTop - MenuStandIn.padding + subSize.height)
        )
        let rect = NSRect(
            x: margin, y: canvas.height - margin - size.height, width: size.width, height: size.height)
        let row = try #require(MenuStandIn.rows(of: menu, in: rect).first { $0.0 === item }?.1)
        let subRect = NSRect(
            x: rect.maxX - 4, y: row.maxY + MenuStandIn.padding - subSize.height, width: subSize.width,
            height: subSize.height)
        return { scale in
            let rep = blankBitmap(width: Int(canvas.width) * scale, height: Int(canvas.height) * scale)
            rep.size = canvas
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: 0.86, alpha: 1).setFill()
            NSRect(origin: .zero, size: canvas).fill()
            MenuStandIn.draw(menu, in: rect)
            MenuStandIn.draw(submenu, in: subRect)
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
    }
}
