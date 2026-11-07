import Foundation

/// The words of ADR 0038 (one book per process; Close Book quits), with every candidate the
/// owner is choosing between. Drafts: each pick is the one line marked below.
public enum OneBookWording {
    /// The File menu item that closes the book, and so quits.
    public enum CloseItem: CaseIterable, Sendable {
        case closeBook
        case closeBookAndQuit
    }

    /// The owner's pick for the menu item.
    public static let closeItem = CloseItem.closeBook

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

    public static var closeBookMenuItem: String { label(closeItem) }

    public static func label(_ item: CloseItem) -> String {
        switch item {
        case .closeBook: "Close Book"
        case .closeBookAndQuit: "Close Book and Quit"
        }
    }

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
                message: "Close \(openName) first (\(menuPath)). Scene It will quit; open it again to "
                    + "choose another book.")
        case .oneBookAtATime:
            return Notice(
                title: "\(openName) is open.",
                message: "Scene It works on one book at a time. To open \(names), choose \(menuPath), "
                    + "which quits Scene It, then open \(names) again.")
        case .closeFirst:
            return Notice(
                title: "Close \(openName) first.",
                message: "Choose \(menuPath), then open \(names) again.")
        }
    }

    // MARK: The book is lost (ADR 0018 → ADR 0038)

    /// After Open Other Version saved the writer's version as a copy, nothing would open in its
    /// place, so Scene It quits once this is dismissed.
    public enum BookLost: CaseIterable, Sendable {
        /// The load failure's own title; the quit comes last, after the backups.
        case quitLast
        /// The quit is in the title; the load failure's message follows.
        case quitInTitle
    }

    /// The owner's pick for the alert.
    public static let bookLost = BookLost.quitLast

    public static func bookLost(_ error: LoadError, myVersion copy: URL) -> Notice {
        bookLost(bookLost, error, myVersion: copy)
    }

    public static func bookLost(_ wording: BookLost, _ error: LoadError, myVersion copy: URL) -> Notice {
        let failed = StoreWording.loadFailed(error, myEditsSavedAs: copy)
        let name = quoted(StoreWording.bookName(error.package))
        switch wording {
        case .quitLast:
            return Notice(
                title: failed.title,
                message: failed.message + "\n\nScene It will quit now. Open it again to choose a book.")
        case .quitInTitle:
            return Notice(title: "Scene It couldn't open \(name), so it will quit.", message: failed.message)
        }
    }

    // MARK: Several books asked for at once

    /// Finder or a launch asked for several books while the process had none: the first opens,
    /// the rest go to Recent Books, which the start state shows only after a relaunch.
    public enum SeveralBooks: CaseIterable, Sendable {
        /// The wording before ADR 0038.
        case addedToRecents
        /// Says how to get to the others: close (quit), then open Scene It again.
        case closeToOpenTheOthers
        /// Short: the others are kept for next time.
        case forNextTime
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
        switch wording {
        case .addedToRecents:
            return Notice(
                title: title,
                message: "\(openName) is open. These books were added to Recent Books instead: \(listed).")
        case .closeToOpenTheOthers:
            return Notice(
                title: title,
                message: "\(openName) is open. \(names) \(others.count == 1 ? "is" : "are") in Recent Books: "
                    + "to open one, choose File → \(closeBookMenuItem), which quits Scene It, then open it again."
            )
        case .forNextTime:
            return Notice(
                title: "Only \(openName) was opened.",
                message: "Scene It opens one book at a time. \(names) \(others.count == 1 ? "is" : "are") "
                    + "in Recent Books for next time.")
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
