/// What comment actions (PLAN §8.1) are called in the Edit menu and in Undo and Redo: the
/// owner's (#23).
public enum CommentWording {
    /// Edit → New Comment (PLAN §11), and its undo: "Undo New Comment".
    public static let newComment = "New Comment"
    public static let editUndoName = "Edit Comment"
    public static let recolorUndoName = "Comment Color"
    public static let dismissUndoName = "Dismiss Comment"
    public static let reanchorUndoName = "Re-anchor Comment"
}

/// What the comments panel (PLAN §8.1) says, in one place so the owner can review it as a
/// whole (#25).
extension CommentWording {
    public static let searchPlaceholder = "Search \u{00B7} try #green"
    public static let searchHelp =
        "Type words to match comment text, and #color (e.g. #green, #grey) to filter by color"
    public static let clearSearch = "Clear Search"
    public static let newCommentHelp = "New comment on the selected text (Cmd+Shift+M)"
    /// The floating button at the end of a selection on the page.
    public static let commentButton = "\u{1F4AC} Comment"
    public static let commentButtonHelp = "Comment on the selection (Cmd+Shift+M)"
    /// Before the chips of the colors the search filters by.
    public static let showing = "Showing"
    public static func unknownColors(_ tokens: [String]) -> String {
        let names = PaletteColor.allCases.map { "#\($0.rawValue)" }.joined(separator: " ")
        return "Unknown color \(tokens.joined(separator: ", ")) (try \(names))"
    }
    /// In an empty card.
    public static let typeAComment = "Type a comment\u{2026}"
    public static func quote(_ text: String) -> String {
        "on \u{201C}\(text)\u{201D}"
    }
    /// Between the separate stretches of text one comment covers, in its card's quote.
    public static let quoteGap = " \u{2026} "
    public static let options = "Comment Options"
    public static let optionsHelp = "Color and dismiss"
    public static let dismiss = "Dismiss"
    public static let reanchor = "Re-anchor to Selection"
    public static let detached = "Detached"
    public static let detachedHelp = "The text these comments were on was deleted."
    public static let noComments =
        "No comments in this scene. Select text, then click \u{1F4AC} Comment beside it or +."
    public static let noMatches = "No comments match."
}
