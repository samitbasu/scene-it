import Foundation

/// What the Scenes sheet (PLAN §7.2) says, and what its changes are called in Undo and Redo, in
/// one place so the owner can review the wording as a whole (#28).
public enum ScenesWording {
    public static let title = "Scenes"
    public static let newScene = "+ New scene"
    public static let newSceneHelp = "Add a scene after the open one"
    public static let newSceneTileHelp = "Add a scene at the end"
    /// Undo and Redo's name for adding a scene.
    public static let newSceneUndoName = "New Scene"
    public static let filterPlaceholder = "Filter scenes"
    public static let viewLabel = "View"
    public static let titleLabel = "Title of the new scene"
    public static let dragHelp = "Dragging to reorder comes in a later version"
    public static let openHelp = "Open this scene"
    public static let noScenes = "No scenes yet."
    public static let noScenesHint = "Add one with + New scene."

    public static func view(_ view: ScenesView) -> String {
        switch view {
        case .cards: "Cards"
        case .lightTable: "Light table"
        }
    }

    /// The header's totals: "24 scenes · 1,409 words".
    public static func totals(scenes: Int, words: WordCount) -> String {
        let scenes = scenes == 1 ? "1 scene" : "\(scenes.formatted()) scenes"
        return "\(scenes) \u{00B7} \(WindowWording.words(words))"
    }

    public static func noMatches(_ filter: String) -> String {
        "No scenes match \u{201C}\(filter.trimmingCharacters(in: .whitespaces))\u{201D}."
    }

    public static let noMatchesHint = "The filter looks in titles, text and tags."

    /// When a card's scene last changed: "just now", "6 hours ago", "yesterday", "2 weeks ago",
    /// in `locale`'s words where it has them (`RelativeDateTimeFormatter`).
    public static func modified(_ age: RelativeAge, locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        var ago = DateComponents()
        switch age {
        case .justNow:
            return "just now"
        case .yesterday:
            formatter.dateTimeStyle = .named
            ago.day = -1
        case .minutes(let count): ago.minute = -count
        case .hours(let count): ago.hour = -count
        case .days(let count): ago.day = -count
        case .weeks(let count): ago.weekOfMonth = -count
        case .months(let count): ago.month = -count
        case .years(let count): ago.year = -count
        }
        return formatter.localizedString(from: ago)
    }
}
