import Foundation

/// Every string Copy Review and Save Review… show or write (review format §6–§7, §9 Q12), in one
/// place so the owner can review the wording as a whole. The report's labels are the spec's
/// draft; the menu items and messages were chosen by default while the owner was away (#81).
public enum ReviewOutputWording {
    public static let copyMenuItem = "Copy Review"
    public static let saveMenuItem = "Save Review…"

    // MARK: The report

    /// The first line: "Review of My Novel".
    public static func heading(_ title: String) -> String {
        "Review of \(title)"
    }

    public static let generalNotes = "General notes"
    public static let sceneNotes = "Notes"
    /// The scene notes' heading in plain text, where it isn't bold.
    public static let sceneNotesPlain = "Notes:"
    public static let untitledScene = "(untitled scene)"

    private static let months = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
        "November", "December",
    ]

    /// "November 4, 2026", in English whatever the Mac's language.
    public static func date(_ day: CalendarDay) -> String {
        "\(months[day.month - 1]) \(day.day), \(day.year)"
    }

    // MARK: The standalone page

    public static let noScript = "JavaScript is turned off, so the boxes you tick won\u{2019}t be remembered."
    public static let noStorage = "This browser won\u{2019}t let the page remember the boxes you tick."
    public static let checkboxLabel = "Done"

    // MARK: The save panel

    public static let panelTitle = "Save Review"
    public static let panelPrompt = "Save"
    public static let fileExtension = "html"
    /// What a page may be saved as: nothing a review or its copy is ever named.
    static let pageExtensions: Set<String> = ["html", "htm"]

    /// "My Novel review.html", from the copy "My Novel.md".
    public static func defaultFileName(copy: URL) -> String {
        copy.deletingPathExtension().lastPathComponent + " review." + fileExtension
    }

    // MARK: Afterwards

    public static let couldntSave = "Scene It couldn't save the review."

    /// What the reviewer is told when nothing was written; nothing at the destination changed.
    public static func notice(for failure: SaveReviewFailure) -> Notice {
        Notice(title: couldntSave, message: reason(failure) + nothingWritten)
    }

    /// The review closed before the save's turn came.
    public static let reviewClosed = Notice(
        title: couldntSave, message: "The review closed before it could be saved." + nothingWritten)

    /// The review had no comments or notes when the save's turn came.
    public static let nothingToSave = Notice(
        title: couldntSave, message: "The review has no comments or notes yet." + nothingWritten)

    private static let nothingWritten = " Nothing was written."

    private static func reason(_ failure: SaveReviewFailure) -> String {
        switch failure {
        case .notAPage: "A review is saved as a web page, a name ending in .html."
        case .reviewsOwnFile:
            "That's the review copy, or where Scene It keeps this review's own files. Choose another place."
        case .destination(.notAFile): ChosenFileWording.notAFile
        case .destination(.writeProtected(let protection)): ChosenFileWording.reason(protection)
        case .destination(.fileSystem(let error)): ChosenFileWording.reason(error)
        }
    }
}

/// Why a write to a place the writer chose failed, as the export and Save Review… both say it.
enum ChosenFileWording {
    static let notAFile = "Something that isn't a file already has that name."

    static func reason(_ protection: WriteProtection) -> String {
        switch protection {
        case .locked: "The file with that name is locked in Finder."
        case .readOnly: "The file with that name is read-only."
        }
    }

    static func reason(_ error: FileSystemError) -> String {
        switch error.cause {
        case .noSpace: "The disk is full."
        case .readOnlyVolume: "The disk is read-only."
        case .permissionDenied: "Scene It doesn't have permission to write there."
        case .notFound, .alreadyExists, .unsupported, .io, .filedCopy, .other:
            "The disk reported an error."
        }
    }
}
