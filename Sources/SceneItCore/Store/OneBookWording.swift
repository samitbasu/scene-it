import Foundation

/// The words of ADR 0038 (one book at a time; Close Book returns to the start screen), in one
/// place so the owner can review them as a whole. The owner chose these on 2026-11-07.
public enum OneBookWording {
    public static let closeBookMenuItem = "Close Book"
    /// The same File menu item (⌘W) on the start screen, where it quits.
    public static let startScreenCloseMenuItem = "Close Window and Quit"

    /// Finder or another launch asked for other books while one is open. `requested` holds at
    /// least one book that isn't `open`.
    public static func refusal(of requested: [URL], whileOpen open: URL) -> Notice {
        let openName = quoted(StoreWording.bookName(open))
        let names = joined(requested.map { quoted(StoreWording.bookName($0)) })
        return Notice(
            title: "\(names) can't be opened while \(openName) is open.",
            message: "Close \(openName) first (File → \(closeBookMenuItem)), then open \(names) again.")
    }

    /// New Book was chosen while an open was already running (the launch reopening the last
    /// book from a slow volume, say, while the start screen shows), and that book opened first.
    public static func createRefusal(of requested: URL, whileOpen open: URL) -> Notice {
        let openName = quoted(StoreWording.bookName(open))
        return Notice(
            title: "\(quoted(StoreWording.bookName(requested))) wasn't created, because \(openName) is open.",
            message: "Close \(openName) first (File → \(closeBookMenuItem)), then choose File → "
                + "\(StoreWording.newBookMenuItem) again.")
    }

    /// After Open Other Version saved the writer's version as a copy, nothing would open in its
    /// place, so the start screen shows, with the copy first in Recent Books. When `error` is
    /// about `copy` itself, the copy is named once, as the book that won't open.
    public static func bookLost(_ error: LoadError, myVersion copy: URL) -> Notice {
        let copyFailed = error.package.canonicalPath == copy.canonicalPath
        let failed = StoreWording.loadFailed(error, myEditsSavedAs: copyFailed ? nil : copy)
        return Notice(
            title: failed.title,
            message: failed.message + "\n\n\(quoted(StoreWording.bookName(copy))) is first in Recent Books.")
    }

    /// Finder or a launch asked for several books on the start screen: the first opens, the rest
    /// go to Recent Books. `open` is the book that opened, if one did.
    public static func severalBooks(open: URL?, addedToRecents others: [URL]) -> Notice {
        let title = "Scene It opens one book at a time."
        guard let open else {
            let listed = others.map { quoted(StoreWording.bookName($0)) }.joined(separator: ", ")
            return Notice(title: title, message: "These books were added to Recent Books instead: \(listed).")
        }
        let names = joined(others.map { quoted(StoreWording.bookName($0)) })
        return Notice(
            title: title,
            message:
                "\(quoted(StoreWording.bookName(open))) is open. \(names) \(others.count == 1 ? "is" : "are") "
                + "in Recent Books: to open one, choose File → \(closeBookMenuItem), then choose it there.")
    }

    /// "“A”", "“A” and “B”", "“A”, “B” and “C”".
    private static func joined(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func quoted(_ name: String) -> String {
        "“\(name)”"
    }
}
