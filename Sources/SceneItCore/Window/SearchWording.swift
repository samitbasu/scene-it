/// Every string the Search sheet shows (PLAN §9.1), in one place so the owner can review the
/// wording as a whole.
public enum SearchWording {
    public static let title = "Search"
    public static let placeholder = "Find text, notes or comments"
    public static let searchTags = "Search tags"
    public static let matchCase = "Match case"
    public static let wholeWord = "Whole word"
    public static let fileCabinet = "File Cabinet"
    public static let scopeLabel = "Scope"
    public static let searchTagsHelp = "Also match scene tags"

    public static func checkbox(_ checkbox: SearchCheckbox) -> String {
        switch checkbox {
        case .searchTags: searchTags
        case .matchCase: matchCase
        case .wholeWord: wholeWord
        }
    }

    public static func scope(_ scope: SearchScope) -> String {
        switch scope {
        case .thisScene: "This scene"
        case .wholeBook: "Whole book"
        }
    }

    /// Before anything is typed.
    public static func prompt(_ scope: SearchScope) -> String {
        switch scope {
        case .thisScene: "Type to search the title, text, notes and comments of this scene."
        case .wholeBook:
            "Type to search titles, text, notes and comments in every scene in the book, including the Boneyard."
        }
    }

    /// Text with no words in it, such as `--` (ADR 0033).
    public static let noWords = "Search finds words. To find punctuation, use Find (Cmd+F) in the scene."
    public static let noSceneOpen = "No scene is open."
    public static let noMatches = "No matches."
    public static let noExactMatches = "No exact matches · Near matches"
    public static let searching = "Searching…"

    public static func matches(_ count: Int) -> String {
        count == 1 ? "1 match" : "\(count.formatted()) matches"
    }

    public static func scenes(_ count: Int) -> String {
        count == 1 ? "1 scene" : "\(count.formatted()) scenes"
    }

    /// "4 matches in 3 scenes", as in the mockup.
    public static func summary(matches: Int, scenes: Int) -> String {
        "\(self.matches(matches)) in \(self.scenes(scenes))"
    }

    public static func moreInScene(_ count: Int) -> String {
        "+\(count.formatted()) more in this scene"
    }

    public static let fewerInScene = "Show fewer"

    /// The near-match limit's button (owner, #31), with every scene the search found.
    public static func showAll(_ scenes: Int) -> String {
        "Show all \(self.scenes(scenes))"
    }

    public static func field(_ field: SearchField) -> String {
        switch field {
        case .title: "TITLE"
        case .body: "TEXT"
        case .notes: "NOTES"
        case .comment: "COMMENT"
        case .tags: "TAGS"
        }
    }

    /// A scene's number in its result group: its place in the story, or the rail's **B**.
    public static func sceneNumber(_ placement: ScenePlacement) -> String {
        switch placement {
        case .story(let number): String(number)
        case .boneyard: WindowWording.boneyardBadge
        }
    }

    public static func sceneTitle(_ title: String) -> String {
        title.isEmpty ? WindowWording.untitledScene : title
    }

    public static let boneyard = WindowWording.boneyard
}
