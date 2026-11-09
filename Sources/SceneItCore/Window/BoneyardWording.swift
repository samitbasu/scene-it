/// The Boneyard tray of the Scenes sheet (PLAN §7.3, mockup 07), and deleting a scene from it
/// (ADR 0031: the words the owner approved on 2026-11-04, #94).
public enum BoneyardWording {
    public static let title = WindowWording.boneyard

    /// "(2)", after the title.
    public static func count(_ scenes: Int) -> String {
        "(\(scenes.formatted()))"
    }

    public static let hint =
        "Scenes cut from the manuscript, kept with their notes and comments. Drag a card here to cut it; "
        + "drag a scene back onto the grid (or click \u{21A9}) to restore it."

    /// A tile's word count: "60 w".
    public static func words(_ count: WordCount) -> String {
        "\(count.words.formatted()) w"
    }

    public static let restore = "Restore"
    public static let restoreHelp = "Restore to the end of the manuscript"
    public static let open = "Open"
    public static let openHelp = "Open this scene, or drag it onto the grid to restore it"
    public static let deletePermanently = "Delete Permanently\u{2026}"

    /// The book closed, or was read again, while Delete Permanently… asked.
    public static func notDeleted(_ scene: BookScene) -> Notice {
        Notice(
            title: "\u{201C}\(WindowWording.sceneName(scene))\u{201D} wasn't deleted.",
            message: "The book closed before it could be deleted. Nothing was changed.")
    }
    /// What Undo and Redo name the delete: "Undo Delete Scene".
    public static let deleteUndoName = "Delete Scene"

    /// Asks before `OpenBook.deleteFromBoneyard(_:)`. Cancel comes first, so Return keeps the scene.
    public static func confirmDelete(_ scene: BookScene) -> WriterAlert<DeleteChoice> {
        WriterAlert(
            title: "Delete “\(WindowWording.sceneName(scene))” from the Boneyard?",
            message: "It's kept at the end of the book file, where you can recover it with a text editor.",
            buttons: [.init(choice: .cancel, label: "Cancel"), .init(choice: .delete, label: "Delete")])
    }
}

public enum DeleteChoice: Hashable, Sendable {
    case cancel
    case delete
}
