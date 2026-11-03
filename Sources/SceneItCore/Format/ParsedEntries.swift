/// An error entry and the line that produced it, so entries found at different times can be
/// put in file order (book format §5.2). Shared by `BookParser` and `ArchiveIndexFormat`.
struct Positioned {
    let line: Int
    let entry: ErrorEntry
    var origin = EntryOrigin.new
    /// The rule the line broke, where the parser knows it.
    var reason: ErrorReason?

    init(line: Int, entry: ErrorEntry, origin: EntryOrigin = .new, reason: ErrorReason? = nil) {
        self.line = line
        self.entry = entry
        self.origin = origin
        self.reason = reason
    }

    /// §5.2's first group: the entries in file order of the lines that produced them.
    static func inFileOrder(_ entries: [Positioned]) -> [Positioned] {
        entries.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(
            \.element)
    }

    /// The ones this parse made (ADR 0024).
    static func new(_ entries: [Positioned]) -> [ErrorEntry] {
        entries.filter { $0.origin == .new }.map(\.entry)
    }

    /// Why the first of them is an error.
    static func firstNewReason(_ entries: [Positioned]) -> ErrorReason? {
        entries.first { $0.origin == .new }.map { $0.reason ?? .line }
    }
}

/// The characters `CharacterPolicy` changed, handed out as a parse reaches the lines they
/// were on, so each part of the file gets notices for its own (§5.3).
struct ChangeCursor {
    private let changes: [CharacterChange]
    private var next = 0

    init(_ changes: [CharacterChange]) {
        self.changes = changes
    }

    /// Those on lines up to `line` not handed out yet.
    mutating func through(line: Int) -> [CharacterChange] {
        let start = next
        while next < changes.count, changes[next].line <= line {
            next += 1
        }
        return Array(changes[start..<next])
    }
}

/// An entry (or a stray line) and the line it started on, so entries found at different
/// times can be put in file order.
struct LogicalLine {
    let line: Int
    var text: [UInt8]
}

extension RepairNotice {
    /// The notice for the front matter's `format` (§1.5), if it isn't the current one.
    static func format(_ declared: Int?) -> [RepairNotice] {
        guard let declared else { return [.missingFormat] }
        return declared == FormatVersion.current.number ? [] : [.otherFormat(declared)]
    }
}
