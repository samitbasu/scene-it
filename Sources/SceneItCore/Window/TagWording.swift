/// What the Tags tab (PLAN §8.3) says, and what its actions are called in Undo and Redo, in one
/// place so the owner can review the wording as a whole (#20).
public enum TagWording {
    public static let addUndoName = "Add Tag"
    public static let removeUndoName = "Remove Tag"

    public static let thisScene = "This scene"
    public static let allTags = "All tags in the book"
    /// After `allTags`, while the open scene's tags can be changed.
    public static let allTagsHint = "click to add or remove on this scene"
    public static let hintSeparator = " \u{00B7} "
    /// The + tag field's placeholder.
    public static let addPlaceholder = "+ tag"
    public static let addHelp = "Type a tag and press Return to add it to this scene"
    public static let addLabel = "New tag for this scene"
    public static let sceneHasNoTags = "No tags on this scene."
    public static let bookHasNoTags = "No scene has a tag yet."

    public static func removeHelp(_ tag: String) -> String {
        "Remove \(SceneTag.shown(tag)) from this scene"
    }

    public static func addRowHelp(_ tag: String) -> String {
        "Add \(SceneTag.shown(tag)) to this scene"
    }

    public static func searchHelp(_ tag: String) -> String {
        "Search the whole book for \(SceneTag.shown(tag))"
    }

    /// A row's count, for VoiceOver: "3 scenes".
    public static func sceneCount(_ count: Int) -> String {
        count == 1 ? "1 scene" : "\(count) scenes"
    }

    /// A row's state for VoiceOver, while the open scene has the tag.
    public static let onThisScene = "On this scene"
}
