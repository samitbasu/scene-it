import AppKit

/// The item titled `title` anywhere under `menu`, searching submenus depth first.
func menuItem(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
    for item in menu?.items ?? [] {
        if item.title == title { return item }
        if let found = menuItem(titled: title, in: item.submenu) { return found }
    }
    return nil
}

/// Chooses `item` as a click would: through its menu, so the app's real action runs.
func perform(_ item: NSMenuItem) throws {
    guard let menu = item.menu else { throw MenuError.detached }
    menu.performActionForItem(at: menu.index(of: item))
}

enum MenuError: Error {
    case detached
}
