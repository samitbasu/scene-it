import Foundation

/// What a filed copy, open read-only (PLAN §7.5), says, in one place so the owner can review the
/// wording as a whole (#33).
public enum FiledCopyWording {
    public static let bannerTitle = "Filed copy"
    public static let readOnly = "\u{2014} read only"
    public static let close = "Close"
    public static let closeHelp = "Back to your book, at the scene you had open"
    public static let moreLabel = "More for this filed copy"
    public static let restoreScene = "Restore This Scene to My Book"
    public static let newBook = "New Book from This Copy\u{2026}"
    /// Undo and Redo's name for a scene restored from a filed copy.
    public static let restoreUndoName = "Restore Scene from Filed Copy"
    public static let newBookPanelTitle = "New Book from This Copy"
    public static let newBookPanelPrompt = "Create"

    /// The banner's detail: "· Oct 13, 2026 · draft 3".
    public static func bannerDetail(_ context: FiledCopyContext) -> String {
        ([""] + [ArchiveWording.day(context.filed)] + context.tags).joined(separator: " \u{00B7} ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The new book's suggested name: "My Novel, Oct 13, 2026".
    public static func newBookName(title: String, _ context: FiledCopyContext) -> String {
        let name = title.isEmpty ? StoreWording.newBookDefaultName : title
        return "\(name), \(ArchiveWording.day(context.filed))"
    }

    public static func couldNotOpen(_ error: FileSystemError) -> Notice {
        Notice(
            title: "The filed copy couldn't be opened.",
            message: "Scene It couldn't read it (\(error)). Nothing was changed.")
    }

    public static func newBookMade(_ url: URL) -> Notice {
        Notice(
            title:
                "\u{201C}\(url.deletingPathExtension().lastPathComponent)\u{201D} was made from this copy.",
            message: "It's in Recent Books. Close this book to open it.")
    }
}
