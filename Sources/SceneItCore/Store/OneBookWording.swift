import Foundation

/// The words of ADR 0038 (one book at a time; Close Book returns to the start screen), with
/// every candidate the owner is choosing between. Drafts: each pick is the one line marked below.
public enum OneBookWording {
    public static let closeBookMenuItem = "Close Book"

    // MARK: ⌘W on the start screen

    /// The File menu item ⌘W chooses on the start screen, where it quits Scene It (if the owner
    /// keeps ⌘W there at all: `BookController.startScreenCommandW`).
    public enum StartScreenCloseItem: CaseIterable, Sendable {
        /// The same item as with a book open.
        case closeBook
        /// Says what it does there.
        case quitFromStartScreen
    }

    /// The owner's pick for the item.
    public static let startScreenCloseItem = StartScreenCloseItem.closeBook

    public static var startScreenCloseMenuItem: String { label(startScreenCloseItem) }

    public static func label(_ item: StartScreenCloseItem) -> String {
        switch item {
        case .closeBook: closeBookMenuItem
        case .quitFromStartScreen: "Close Window and Quit"
        }
    }

    // MARK: Another book while one is open

    /// The alert shown when Finder or another launch asks for another book while one is open.
    public enum Refusal: CaseIterable, Sendable {
        /// The book that can't be opened is the title; the body says how to get to it.
        case cantOpenWhileOpen
        /// The title names the open book; the body explains in one sentence.
        case oneBookAtATime
        /// The shortest: the instruction is the title.
        case closeFirst
    }

    /// The owner's pick for the alert.
    public static let refusal = Refusal.cantOpenWhileOpen

    public static func refusal(of requested: [URL], whileOpen open: URL) -> Notice {
        refusal(refusal, of: requested, whileOpen: open)
    }

    /// `requested` holds at least one book that isn't `open`.
    public static func refusal(_ wording: Refusal, of requested: [URL], whileOpen open: URL) -> Notice {
        let openName = quoted(StoreWording.bookName(open))
        let names = joined(requested.map { quoted(StoreWording.bookName($0)) })
        let menuPath = "File → \(closeBookMenuItem)"
        switch wording {
        case .cantOpenWhileOpen:
            return Notice(
                title: "\(names) can't be opened while \(openName) is open.",
                message: "Close \(openName) first (\(menuPath)), then open \(names) again.")
        case .oneBookAtATime:
            return Notice(
                title: "\(openName) is open.",
                message: "Scene It works on one book at a time. To open \(names), choose \(menuPath), "
                    + "then open \(names) again.")
        case .closeFirst:
            return Notice(
                title: "Close \(openName) first.",
                message: "Choose \(menuPath), then open \(names) again.")
        }
    }

    // MARK: The book is lost (ADR 0018 → ADR 0038)

    /// After Open Other Version saved the writer's version as a copy, nothing would open in its
    /// place, so the start screen shows, with the copy first in Recent Books.
    public enum BookLost: CaseIterable, Sendable {
        /// The load failure's own title; the message ends by pointing at Recent Books.
        case recentBooksLast
        /// The title says the book was closed; the load failure's message follows.
        case closedInTitle
    }

    /// The owner's pick for the alert.
    public static let bookLost = BookLost.recentBooksLast

    public static func bookLost(_ error: LoadError, myVersion copy: URL) -> Notice {
        bookLost(bookLost, error, myVersion: copy)
    }

    /// When `error` is about `copy` itself, the copy is named once, as the book that won't open.
    public static func bookLost(_ wording: BookLost, _ error: LoadError, myVersion copy: URL) -> Notice {
        let copyFailed = error.package.canonicalPath == copy.canonicalPath
        let failed = StoreWording.loadFailed(error, myEditsSavedAs: copyFailed ? nil : copy)
        let name = quoted(StoreWording.bookName(error.package))
        let copyName = quoted(StoreWording.bookName(copy))
        switch wording {
        case .recentBooksLast:
            return Notice(
                title: failed.title,
                message: failed.message + "\n\n\(copyName) is first in Recent Books.")
        case .closedInTitle:
            return Notice(
                title: "Scene It couldn't open \(name), so it closed the book.", message: failed.message)
        }
    }

    // MARK: Several books asked for at once

    /// Finder or a launch asked for several books in the start state: the first opens, the rest
    /// go to Recent Books, which the start screen shows once the open book is closed.
    public enum SeveralBooks: CaseIterable, Sendable {
        /// The wording before ADR 0038.
        case addedToRecents
        /// Says how to get to the others: close the open book, then choose one.
        case closeToOpenTheOthers
        /// Short: the others are kept in Recent Books.
        case inRecentBooks
    }

    /// The owner's pick for the notice (still the wording from before ADR 0038).
    public static let severalBooks = SeveralBooks.addedToRecents

    /// `open` is the book that opened, if one did.
    public static func severalBooks(open: URL?, addedToRecents others: [URL]) -> Notice {
        severalBooks(severalBooks, open: open, addedToRecents: others)
    }

    public static func severalBooks(_ wording: SeveralBooks, open: URL?, addedToRecents others: [URL])
        -> Notice
    {
        let names = joined(others.map { quoted(StoreWording.bookName($0)) })
        let listed = others.map { quoted(StoreWording.bookName($0)) }.joined(separator: ", ")
        let title = "Scene It opens one book at a time."
        guard let open else {
            return Notice(title: title, message: "These books were added to Recent Books instead: \(listed).")
        }
        let openName = quoted(StoreWording.bookName(open))
        let are = others.count == 1 ? "is" : "are"
        switch wording {
        case .addedToRecents:
            return Notice(
                title: title,
                message: "\(openName) is open. These books were added to Recent Books instead: \(listed).")
        case .closeToOpenTheOthers:
            return Notice(
                title: title,
                message: "\(openName) is open. \(names) \(are) in Recent Books: to open one, choose "
                    + "File → \(closeBookMenuItem), then choose it there.")
        case .inRecentBooks:
            return Notice(
                title: "Only \(openName) was opened.",
                message: "Scene It opens one book at a time. \(names) \(are) in Recent Books.")
        }
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
