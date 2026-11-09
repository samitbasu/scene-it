import Foundation

/// Every string Export to Word shows (PLAN §10.2, §11), in one place so the owner can review the
/// wording as a whole. Chosen by default while the owner was away (#37): see the PR.
public enum WordExportWording {
    public static let menuItem = "Export to Word…"

    // MARK: The save panel

    public static let panelTitle = "Export to Word"
    public static let panelPrompt = "Export"
    public static let fileExtension = "docx"

    /// "The ferry.docx", or "Untitled scene.docx".
    public static func defaultFileName(scene: BookScene, package: URL) -> String {
        StoreWording.fileNameBase(title: WindowWording.sceneName(scene), package: package) + "."
            + fileExtension
    }

    // MARK: Afterwards

    public static let couldntExport = "Scene It couldn't export the scene to Word."

    /// What the writer is told when nothing was written; nothing at the destination changed.
    public static func notice(for failure: WordExportFailure) -> Notice {
        Notice(title: couldntExport, message: reason(failure) + nothingWritten)
    }

    /// The book closed, or the scene went, before the export's turn came.
    public static let sceneClosed = Notice(
        title: couldntExport, message: "The scene closed before it could be exported." + nothingWritten)

    private static let nothingWritten = " Nothing was written."

    private static func reason(_ failure: WordExportFailure) -> String {
        switch failure {
        case .notAWordDocument: "A Word document is saved with a name ending in .docx."
        case .conversion: "macOS couldn't make a Word document of the scene."
        case .destination(.notAFile): ChosenFileWording.notAFile
        case .destination(.writeProtected(let protection)): ChosenFileWording.reason(protection)
        case .destination(.fileSystem(let error)): ChosenFileWording.reason(error)
        }
    }
}
