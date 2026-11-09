/// Every string the Search sheet shows (PLAN §9.1), in one place so the owner can review the
/// wording as a whole.
public enum SearchWording {
    public static let title = "Search"
    public static let placeholder = "Find text, notes or comments"
    public static let searchTags = "Search tags"
    public static let matchCase = "Match case"
    public static let wholeWord = "Whole word"
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
        case .fileCabinet: FileCabinetWording.title
        }
    }

    /// Before anything is typed.
    public static func prompt(_ scope: SearchScope) -> String {
        switch scope {
        case .thisScene: "Type to search the title, text, notes and comments of this scene."
        case .wholeBook:
            "Type to search titles, text, notes and comments in every scene in the book, including the Boneyard."
        case .fileCabinet:
            "Type to search titles, text, notes and comments in the filed copies. Each opens read-only."
        }
    }

    // MARK: The File Cabinet scope (#34)

    public static let copyPickerLabel = "Filed copies"
    public static let filedFrom = "filed from"
    public static let noFiledCopies = FileCabinetWording.noCopies
    public static let noCopiesInRange = "No filed copies were filed in these dates."
    public static let opensReadOnly = "opens read-only"
    /// The group of a copy's own tags, in place of a scene's number and title.
    public static let copyTags = "Tags of this copy"

    /// The copy picker's first item: "All filed copies (5)", or "All filed copies in range (3)"
    /// while the dates narrow them.
    public static func allCopies(_ count: Int, _ dates: FiledDates) -> String {
        dates.isOpen
            ? "All filed copies (\(count.formatted()))" : "All filed copies in range (\(count.formatted()))"
    }

    /// A copy in the picker, and its result group's heading: "Oct 30, 2026 · beta readers, draft 3".
    public static func copy(_ copy: FiledCopy) -> String {
        ([ArchiveWording.day(copy.filed)] + (copy.tags.isEmpty ? [] : [copy.tags.joined(separator: ", ")]))
            .joined(separator: " \u{00B7} ")
    }

    /// While copies are read for the first time: "Reading filed copies… 12 of 50".
    public static func reading(_ read: Int, of count: Int) -> String {
        "Reading filed copies\u{2026} \(read.formatted()) of \(count.formatted())"
    }

    /// "12 matches in 9 scenes across 3 filed copies · tags match on 2 copies" (PLAN §9.1).
    public static func cabinetSummary(_ counts: CabinetCounts) -> String {
        var parts: [String] = []
        if counts.scenes > 0 {
            let copies = counts.copies == 1 ? "1 filed copy" : "\(counts.copies.formatted()) filed copies"
            parts.append("\(summary(matches: counts.matches, scenes: counts.scenes)) across \(copies)")
        }
        if counts.taggedCopies > 0 {
            let copies = counts.taggedCopies == 1 ? "1 copy" : "\(counts.taggedCopies.formatted()) copies"
            parts.append(parts.isEmpty ? "Tags match on \(copies)" : "tags match on \(copies)")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "No exact matches · Near matches · …", in the File Cabinet.
    public static func cabinetNearSummary(_ counts: CabinetCounts) -> String {
        "\(noExactMatches) \u{00B7} \(cabinetSummary(counts))"
    }

    /// Copies that couldn't be read, so weren't searched.
    public static func unreadable(_ count: Int) -> String {
        count == 1
            ? "1 filed copy couldn't be read, so it wasn't searched."
            : "\(count.formatted()) filed copies couldn't be read, so they weren't searched."
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

    /// "No exact matches · Near matches · 66 matches in 26 scenes".
    public static func nearSummary(matches: Int, scenes: Int) -> String {
        "\(noExactMatches) · \(summary(matches: matches, scenes: scenes))"
    }

    /// After a Boneyard scene's title in its result group: " · Boneyard".
    public static let boneyardSuffix = " · \(WindowWording.boneyard)"

    public static func moreInScene(_ count: Int) -> String {
        "+\(count.formatted()) more in this scene"
    }

    public static let fewerInScene = "Show fewer"

    /// The near-match limit's button (owner, #31), with every scene the search found.
    public static func showAll(_ scenes: Int) -> String {
        "Show all \(self.scenes(scenes))"
    }

    public static func field(_ source: SearchSource) -> String {
        switch source {
        case .scene(_, .title): "TITLE"
        case .scene(_, .body): "TEXT"
        case .scene(_, .notes): "NOTES"
        case .scene(_, .comment): "COMMENT"
        case .scene(_, .tags), .copyTags: "TAGS"
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
}
