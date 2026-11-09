import Foundation

/// What a reviewer reads about Review Book… (ADR 0029, 0041), in one place so the owner can
/// review the wording as a whole. Defaults chosen while the owner was away (#80).
public enum ReviewWording {
    public static let menuItem = "Review Book…"
    public static let panelTitle = "Review a Book"
    public static let panelPrompt = "Review"
    public static let panelMessage =
        "Choose a review copy (a .md file exported from Scene It) or its .review.md file."

    // MARK: The banner

    public static func bannerTitle(_ title: String) -> String {
        "Reviewing “\(title)”"
    }

    public static let bannerDetail =
        "the text is read-only · your comments and notes are saved beside the copy"

    // MARK: Opening

    public static func openFailed(_ error: ReviewOpenError) -> Notice {
        switch error {
        case .unreadable(let error):
            Notice(
                title: "Scene It couldn't open this file.",
                message: "It couldn't be read (\(error.cause)). Nothing was changed.")
        case .notAReviewCopy(let url):
            Notice(
                title: "“\(url.lastPathComponent)” isn't a review copy.",
                message:
                    "Review Book… opens the .md file a writer exported with File → \(ExportWording.menuItem), "
                    + "or the .review.md file beside it. To open a Scene It book, use File → "
                    + "\(StoreWording.openBookMenuItem)")
        case .newerCopy(let url, let format):
            Notice(
                title: "“\(url.lastPathComponent)” was exported by a newer Scene It.",
                message:
                    "It's in book format \(format), which this version can't read without losing something. "
                    + "Update Scene It, then open it again.")
        case .copyNotFound(let review):
            Notice(
                title: "Scene It can't find the review copy for “\(review.lastPathComponent)”.",
                message: "A review opens with the copy it reviews, which must be in the same folder. Put the "
                    + "copy beside it, then open it again.")
        case .reviewUnreadable(let error):
            Notice(
                title: "Scene It couldn't read this copy's review.",
                message:
                    "Its review file couldn't be read (\(error.cause)), so the copy wasn't opened. Nothing "
                    + "was changed.")
        }
    }

    /// Review format §4.3: a review of another copy already has this copy's review file name.
    public static func otherReviewKept(_ other: URL) -> Notice {
        Notice(
            title: "This review will be saved separately.",
            message:
                "“\(other.lastPathComponent)” is a review of a different copy, so Scene It won't change it. "
                + "Your comments and notes on this copy will be saved in a new file beside it.")
    }

    // MARK: Changed on disk (ADR 0018)

    /// A review's file changed under it. A review isn't a book that could be kept as a second copy,
    /// so there's one way on: the reviewer's version is saved, with the other kept as a backup.
    public static func externalChangeAlert(_ error: SaveError) -> WriterAlert<ExternalChangeChoice> {
        let keepLabel = "Keep My Version"
        let keep = [WriterAlert<ExternalChangeChoice>.Button(choice: .keepMyVersion, label: keepLabel)]
        let alert = { (message: String, buttons: [WriterAlert<ExternalChangeChoice>.Button]) in
            WriterAlert(title: QuitWording.changedOnDiskTitle, message: message, buttons: buttons)
        }
        let backup =
            "\(keepLabel) saves your version and keeps the other one as a backup in Scene It's folder "
            + "for this review."
        switch error {
        case .externallyModified(.changed):
            return alert(
                "Another program saved a different version of this review while you were working. Scene It "
                    + "stopped saving so neither version is lost.\n\n" + backup, keep)
        case .externallyModified(.removed):
            return alert(
                "Another program removed this review's file while you were working. Scene It stopped saving."
                    + "\n\n\(keepLabel) saves your version in its place.", keep)
        case .externallyModified(.notAFile):
            return alert(
                "Another program replaced this review's file with something Scene It can't save over. Scene It "
                    + "stopped saving. Move that item away, then choose Try Again.",
                [.init(choice: .keepMyVersion, label: "Try Again")])
        case .externallyModified(.keptAsConflict(let fileName)):
            return alert(
                "Another program changed this review while Scene It was saving it. Your version was saved, and "
                    + "the other version was kept in Scene It's folder for this review as “\(fileName)”.",
                [.init(choice: .keepMyVersion, label: "Continue")])
        case .couldNotBackUpTheirVersion(let fileSystemError):
            return alert(
                "Scene It couldn't keep a backup of the other version (\(fileSystemError.cause)), so it didn't "
                    + "save over it.\n\n\(keepLabel) tries again.", keep)
        case .encoding, .writeProtected, .fileSystem:
            return alert(backup, keep)
        }
    }
}
