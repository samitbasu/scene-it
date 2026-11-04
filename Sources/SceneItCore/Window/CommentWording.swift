/// What comment actions (PLAN §8.1) are called in the Edit menu and in Undo and Redo. "New
/// Comment" is PLAN §11's; the undo names are proposals awaiting the owner (#23).
public enum CommentWording {
    /// Edit → New Comment (PLAN §11), and its undo: "Undo New Comment".
    public static let newComment = "New Comment"
    public static let editUndoName = "Edit Comment"
    public static let recolorUndoName = "Comment Color"
    public static let dismissUndoName = "Dismiss Comment"
    public static let reanchorUndoName = "Re-anchor Comment"
}
