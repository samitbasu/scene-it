import Foundation

/// Every string Export as SceneIt… shows (ADR 0029), in one place so the owner can review the
/// wording as a whole. Chosen by default while the owner was away (#79): see the PR.
public enum ExportWording {
    public static let menuItem = "Export as SceneIt…"

    // MARK: The chooser

    public static let dialogTitle = "Export as SceneIt"
    public static let dialogExplanation =
        "Saves the ticked scenes' text, with bold, italic and strikethrough, as one file to send to a "
        + "reader. Notes, comments, tags, colors and the Boneyard stay in your book."
    public static let selectAll = "Select All"
    public static let selectNone = "Select None"
    public static let rangeHint = "Shift-click to tick or untick a run of scenes."
    public static let cancel = "Cancel"
    public static let confirm = "Export…"

    /// "12 of 24 scenes".
    public static func tickedCount(_ ticked: Int, of total: Int) -> String {
        "\(ticked) of \(total) \(total == 1 ? "scene" : "scenes")"
    }

    /// A row: "3. The letter".
    public static func row(_ row: ExportChoice.Row) -> String {
        "\(row.number). \(row.name)"
    }

    // MARK: The save panel

    public static let panelTitle = "Export as SceneIt"
    public static let panelPrompt = "Export"
    public static let fileExtension = "md"

    /// "My Novel.md".
    public static func defaultFileName(title: String, package: URL) -> String {
        StoreWording.fileNameBase(title: title, package: package) + "." + fileExtension
    }

    // MARK: Afterwards

    public static let couldntExport = "Scene It couldn't export the scenes."

    /// What the writer is told when nothing was written; nothing at the destination changed.
    public static func notice(for failure: ExportFailure) -> Notice {
        Notice(title: couldntExport, message: reason(failure) + nothingWritten)
    }

    /// The book closed, or was read again, before the export's turn came.
    public static let bookClosed = Notice(
        title: couldntExport, message: "The book closed before it could be exported." + nothingWritten)

    private static let nothingWritten = " Nothing was written."

    private static func reason(_ failure: ExportFailure) -> String {
        switch failure {
        case .insideTheBook: "That's inside the book itself. Choose a place outside it."
        case .bookUnidentified:
            "Scene It couldn't identify the book on its disk, so it can't make sure the file stays "
                + "outside the book."
        case .notAFile: ChosenFileWording.notAFile
        case .writeProtected(let protection): ChosenFileWording.reason(protection)
        case .verification: "Scene It found a problem in the scenes while preparing the file."
        case .fileSystem(let error): ChosenFileWording.reason(error)
        }
    }
}
