import Foundation

/// What the File Cabinet sheet (PLAN §7.4) says, in one place so the owner can review the wording
/// as a whole (#33).
public enum FileCabinetWording {
    public static let title = "File Cabinet"
    public static let searchPlaceholder = "Search tags or notes"
    public static let from = "From"
    public static let to = "to"
    public static let clearDates = "Clear the dates"
    public static let openHelp = "Double-click to open this copy read-only"
    public static let noCopies = "No filed copies yet."
    public static let noCopiesHint = "File a Copy… keeps a read-only copy of the whole book here."
    public static let noMatches = "No filed copies match."
    public static let noMatchesHint = "The search looks in tags and notes."
    public static let tagChosenHelp = "Showing copies with this tag; click to show all"
    public static let tagHelp = "Show only copies with this tag"

    /// The header's line: "5 filed copies · double-click one to open it read-only" (ADR 0046).
    public static func subtitle(copies: Int) -> String {
        let count = copies == 1 ? "1 filed copy" : "\(copies.formatted()) filed copies"
        return copies == 0 ? count : count + " \u{00B7} double-click one to open it read-only"
    }

    /// The card's heading: "Oct 30, 2026".
    public static func date(_ day: CalendarDay) -> String {
        ArchiveWording.day(day)
    }

    /// The card's line: "2 days ago · 24 scenes · 1,409 words · 3 comments"; only the age when the
    /// counts aren't known.
    public static func details(_ age: FiledAge, _ counts: FiledCopyCounts?, locale: Locale = .current)
        -> String
    {
        var parts = [self.age(age, locale: locale)]
        if let counts {
            parts += [
                counts.scenes == 1 ? "1 scene" : "\(counts.scenes.formatted()) scenes",
                WindowWording.words(WordCount(words: counts.words)),
                counts.comments == 1 ? "1 comment" : "\(counts.comments.formatted()) comments",
            ]
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    public static func age(_ age: FiledAge, locale: Locale = .current) -> String {
        switch age {
        case .today: "today"
        case .yesterday: ScenesWording.modified(.yesterday, locale: locale)
        case .ago(let age): ScenesWording.modified(age, locale: locale)
        case .future: "later"
        }
    }

    // MARK: Tags on a card

    /// What the writer is told when a copy's tags couldn't be saved to the File Cabinet's list.
    public static func tagsNotSaved(_ failure: RecordEditFailure) -> Notice {
        let reason =
            switch failure {
            case .notInIndex:
                "The File Cabinet's list doesn't hold that copy any more, so nothing was changed."
            case .newerFormat:
                "The File Cabinet's list was saved by a newer version of Scene It, so this version leaves "
                    + "it as it is."
            case .couldNotRead, .notWritten:
                "Scene It couldn't save the File Cabinet's list, so the copy's tags are as they were. "
                    + "The filed copy itself is never changed."
            case .unavailable:
                "The book isn't open for editing, so nothing was changed."
            }
        return Notice(title: "The tag wasn't changed.", message: reason)
    }
}
