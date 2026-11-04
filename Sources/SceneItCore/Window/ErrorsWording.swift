/// Every string the Errors tab and the read-only banner show (book format §5.4, ADR 0024), in
/// one place so the owner can review the wording as a whole. The owner approved all of it on
/// 2026-11-02 (#63, #67), with the notices' own text, `RepairNotice.payload` (book format §5.3).
/// Make Editable… confirms with `ReadOnlyWording.confirmMakeEditable(_:)`.
public enum ErrorsWording {
    // MARK: The tab

    public static let tabName = "Errors"

    public static func count(_ count: Int) -> String {
        "\(count)"
    }

    public static let bookGroup = "Book"
    /// The only place a deleted scene is named (book format §10 Q17; approved 2026-11-04).
    public static let deletedGroup = "Deleted"

    /// A group's heading: the book, or the scene the entries belong to.
    public static func group(_ owner: ErrorOwner, in book: Book) -> String {
        switch owner {
        case .book:
            return bookGroup
        case .scene(let id):
            switch SceneLocation(of: id, in: book) {
            case .story(let scene, let number, _): return "\(number). \(WindowWording.sceneName(scene))"
            case .boneyard(let scene): return "\(WindowWording.boneyard) › \(WindowWording.sceneName(scene))"
            case .noScene:
                guard let deleted = book.deleted.first(where: { $0.id == id }) else {
                    return WindowWording.untitledScene
                }
                return "\(deletedGroup) › \(WindowWording.sceneName(deleted))"
            }
        }
    }

    public static func tag(_ tag: ErrorTag) -> String {
        switch tag {
        case .frontMatter: "Book details"
        case .metadata: "Scene details"
        case .comments: "Comment"
        case .marks: "Color or highlight"
        case .line: "Line"
        case .notice: "Notice"
        }
    }

    public static let empty = "No errors. Scene It reads every line of this book."

    // MARK: Reasons

    public static func reason(_ reason: ErrorReason) -> String {
        switch reason {
        case .comment(.paletteName): "Unknown color name."
        case .comment(let problem), .mark(let problem): self.problem(problem)
        case .metadata(let problem): field(problem, keys: "id, modified and tags")
        case .frontMatter(let problem): field(problem, keys: "title and format")
        case .line: "Scene It couldn't tell where this line belongs, so it kept it here."
        case .notice: "Scene It made this repair while opening the book. Delete this once you've checked it."
        case .readsNow: "This reads correctly now. Choose \(fix) to put it back."
        }
    }

    private static let datePattern = "2026-10-31T20:40:00-07:00"

    private static func problem(_ problem: EntryProblem) -> String {
        switch problem {
        case .strayLine: "Not an entry: entries start with “- ”."
        case .fields: "Fields are missing, empty or out of order."
        case .commentID: "The comment's id isn't valid, or another comment in this scene has it."
        case .paletteName: "Unknown color name, or a mark that isn't “color” or “highlight”."
        case .timestamp: "The date isn't written like \(datePattern)."
        case .rangeSyntax: "The range isn't written like c12-18."
        case .rangeBounds: "The range is outside the scene's text."
        case .quoteSyntax: "A quote is missing or unfinished."
        case .quoteMismatch: "The quote doesn't match the scene's text at that range."
        case .leftover: "There's extra text after the quote."
        }
    }

    private static func field(_ problem: FieldProblem, keys: String) -> String {
        switch problem {
        case .notAField: "Not a “key: value” line."
        case .unknownKey: "Unknown key: the keys are \(keys)."
        case .repeatedKey: "This key appears twice."
        case .badID: "An id is 1 to 64 letters, digits, “-” or “_”."
        case .idInUse: "Another scene already has this id."
        case .badDate: "The date isn't written like \(datePattern)."
        case .badFormat: "The format isn't a number."
        case .otherFormat: "This version of Scene It reads format \(FormatVersion.current)."
        }
    }

    // MARK: Actions

    public static let copy = "Copy"
    public static let delete = "Delete"
    public static let fix = "Fix"
    /// What Undo and Redo name these operations: "Undo Delete Entry".
    public static let deleteUndoName = "Delete Entry"
    public static let fixUndoName = "Fix Entry"
    public static let apply = "Apply"
    public static let cancel = "Cancel"

    /// Under a line the writer fixed that still doesn't read.
    public static func stillUnreadable(_ reason: ErrorReason) -> String {
        "Still can't read this line: " + self.reason(reason)
    }

    /// When Apply can't act: the book went read-only, or the entry changed.
    public static let cantApply =
        "Scene It can't change this entry now. The book is read-only, or the entry has changed."

    // MARK: The read-only banner (#67)

    public struct Banner: Hashable, Sendable {
        public let title: String
        public let detail: String
        /// Offered only for a book repaired as it opened (ADR 0024).
        public let offersMakeEditable: Bool
    }

    /// Shown for the two reasons that are about the book's own content; the others are about
    /// where else it's open, which the status bar and the open-time alert cover.
    public static func banner(for reason: ReadOnlyReason) -> Banner? {
        switch reason {
        case .repairedOnOpen(let repair):
            Banner(
                title: "Repaired while opening",
                detail: "\(repairs(repair.newEntries.count)) · read only",
                offersMakeEditable: true)
        case .newerFormat(let format):
            Banner(
                title: "Saved by a newer Scene It",
                detail: "book format \(format) · read only",
                offersMakeEditable: false)
        case .openElsewhere, .openOnAnotherMac, .openInAnotherProcess, .lockUnavailable:
            nil
        }
    }

    public static let makeEditableItem = ReadOnlyWording.makeEditable + "…"
    public static let showRepairs = "Show Repairs"

    private static func repairs(_ count: Int) -> String {
        count == 1 ? "1 repair" : "\(count) repairs"
    }
}
