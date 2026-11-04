/// Deleting a scene from the Boneyard (ADR 0031): the words the owner approved on 2026-11-04
/// (#94), kept here for the Boneyard's UI.
public enum BoneyardWording {
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
