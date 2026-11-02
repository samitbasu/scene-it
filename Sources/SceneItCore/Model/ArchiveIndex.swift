/// `Archive/index.md` (book format §8): what the writer recorded about each filed copy.
public struct ArchiveIndex: Hashable, Sendable {
    /// Ascending by number, at most one per number.
    public var copies: [FiledCopy]
    /// What the parser found outside any copy's section and couldn't understand, kept
    /// verbatim until the writer deletes it.
    public var errors: [ErrorEntry]

    public init(copies: [FiledCopy] = [], errors: [ErrorEntry] = []) {
        self.copies = copies
        self.errors = errors
    }

    /// Every error entry: the index's own, then each copy's.
    public var errorEntries: [[ErrorEntry]] {
        [errors] + copies.map(\.errors)
    }
}

/// One filed copy's section of the index.
public struct FiledCopy: Hashable, Sendable {
    public var number: FiledCopyNumber
    /// The date the writer gave (PLAN §7.1).
    public var filed: CalendarDay
    /// Each is text `CharacterPolicy` admits, and none is empty: every assignment applies
    /// the policy and drops empty tags.
    public var tags: [String] {
        didSet { tags = Self.admitted(tags) }
    }
    /// Text `CharacterPolicy` admits, which may hold line breaks; every assignment applies
    /// the policy.
    public var note: String {
        didSet { note = CharacterPolicy.admitted(note) }
    }
    /// `nil` when the index had none, or a bad one: they're a cache of facts about the filed
    /// copy, recomputed from it rather than reported.
    public var counts: FiledCopyCounts?
    public var errors: [ErrorEntry]

    public init(
        number: FiledCopyNumber, filed: CalendarDay, tags: [String] = [], note: String = "",
        counts: FiledCopyCounts? = nil, errors: [ErrorEntry] = []
    ) {
        self.number = number
        self.filed = filed
        self.tags = Self.admitted(tags)
        self.note = CharacterPolicy.admitted(note)
        self.counts = counts
        self.errors = errors
    }

    private static func admitted(_ tags: [String]) -> [String] {
        tags.map(CharacterPolicy.admitted).filter { !$0.isEmpty }
    }
}

/// How big a filed copy is, as the File Cabinet lists it.
public struct FiledCopyCounts: Hashable, Sendable {
    public let scenes: Int
    public let words: Int
    public let comments: Int

    /// `nil` if any count is negative.
    public init?(scenes: Int, words: Int, comments: Int) {
        guard scenes >= 0, words >= 0, comments >= 0 else { return nil }
        self.scenes = scenes
        self.words = words
        self.comments = comments
    }
}
