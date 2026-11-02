/// What the main window shows over an open book: the page, or one of the rail's sheets, which
/// cover the page and the right panel (PLAN §4.2). Whether the book can be edited is the
/// book's own state (`OpenBook.isEditable`), so it isn't repeated here.
public enum WindowMode: Hashable, Sendable, CaseIterable {
    case page
    case scenes
    case search
    case fileCabinet

    /// After clicking `item` on the rail: an open sheet's own icon closes it, and any other
    /// icon shows its sheet, or the page for Current scene.
    public func choosing(_ item: WindowMode) -> WindowMode {
        item == self ? .page : item
    }

    /// After Esc, ×, or opening a scene from inside a sheet.
    public var closingSheet: WindowMode {
        .page
    }

    /// Whether the rail highlights `item`: Current scene while the page shows, otherwise the
    /// open sheet.
    public func highlights(_ item: WindowMode) -> Bool {
        item == self
    }

    public var isSheet: Bool {
        self != .page
    }
}
