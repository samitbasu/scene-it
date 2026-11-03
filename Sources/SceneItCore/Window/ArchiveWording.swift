import Foundation

/// Every string File a Copy shows (PLAN §7.1), in one place so the owner can review the wording
/// as a whole. Drafts awaiting the owner's approval (#32); the dialog's text follows the mockup
/// (14-file-a-copy-dialog.png).
public enum ArchiveWording {
    public static let menuItem = "File a Copy…"

    // MARK: The dialog

    public static let dialogTitle = "File a copy"
    public static let dialogExplanation =
        "Saves a read-only copy of the whole manuscript, with every scene's notes and comments, "
        + "to the File Cabinet."
    public static let tagsLabel = "Tags"
    public static let tagsPlaceholder = "Type a tag, press Return"
    public static let dateLabel = "Date"
    public static let noteLabel = "Note"
    public static let cancel = "Cancel"
    public static let confirm = "File copy"

    public static func removeTag(_ tag: String) -> String {
        "Remove \(tag)"
    }

    // MARK: Afterwards

    /// The toast: "Filed in the File Cabinet · Nov 3, 2026 · draft 4".
    public static func toast(_ record: FilingRecord) -> String {
        (["Filed in the File Cabinet", day(record.filed)] + record.tags.prefix(2)).joined(separator: " · ")
    }

    public static func day(_ day: CalendarDay) -> String {
        day.noon(in: .current).formatted(date: .abbreviated, time: .omitted)
    }

    /// What the writer is told after File copy, when something didn't happen; `nil` when the
    /// copy is filed, locked and indexed (the toast says so).
    public static func notice(for result: FilingResult) -> Notice? {
        switch result {
        case .unavailable:
            return nil
        case .failed(let failure):
            return Notice(title: "Scene It couldn't file a copy.", message: reason(failure))
        case .filed(let outcome):
            var problems: [String] = []
            if case .notLocked = outcome.lock { problems.append(notLocked) }
            if case .notUpdated(let failure) = outcome.index { problems.append(reason(failure)) }
            guard !problems.isEmpty else { return nil }
            return Notice(
                title: "The copy was filed, but not everything worked.",
                message: problems.joined(separator: "\n\n"))
        }
    }

    private static func reason(_ failure: FilingFailure) -> String {
        switch failure {
        case .save(let error):
            "The book couldn't be saved first. " + QuitWording.reason(error)
        case .stillSaving:
            "The book is still being saved. Try again in a moment."
        case .bookChangedOnDisk:
            "Another program changed the book while it was being filed."
        case .copyDiffers:
            "The copy didn't match the book when it was read back, so it wasn't kept."
        case .archiveNotAFolder:
            "Something that isn't a folder is where the book's Archive folder should be."
        case .noFreeNumber:
            "Scene It couldn't find a free name for the copy in the book's Archive folder."
        case .fileSystem(let error):
            "The disk reported a problem: \(error.cause)."
        }
    }

    private static let notLocked =
        "This disk can't lock files, so other programs could change the copy. Scene It never will."

    private static func reason(_ failure: IndexFailure) -> String {
        switch failure {
        case .newerFormat:
            "The File Cabinet's list was saved by a newer version of Scene It, so this version leaves "
                + "it as it is. The copy will be listed without its tags or note."
        case .couldNotRead, .notWritten:
            "Scene It couldn't save the copy's tags and note to the File Cabinet's list. The copy will "
                + "be listed without them."
        }
    }
}
