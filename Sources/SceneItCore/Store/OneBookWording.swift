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

    /// "“A”", "“A” and “B”", "“A”, “B” and “C”".
    private static func joined(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func quoted(_ name: String) -> String {
        "“\(name)”"
    }
}
