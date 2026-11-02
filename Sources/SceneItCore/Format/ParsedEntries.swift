/// An error entry and the line that produced it, so entries found at different times can be
/// put in file order (book format §5.2). Shared by `BookParser` and `ArchiveIndexFormat`.
struct Positioned {
    let line: Int
    let entry: ErrorEntry
    var origin = EntryOrigin.new

    init(line: Int, entry: ErrorEntry, origin: EntryOrigin = .new) {
        self.line = line
        self.entry = entry
        self.origin = origin
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
}

/// The characters `CharacterPolicy` replaced with `[?]`, handed out as a parse reaches the
/// lines they were on, so each part of the file gets a notice for its own (§5.3).
struct ReplacementCursor {
    private let replacements: [Replacement]
    private var next = 0

    init(_ replacements: [Replacement]) {
        self.replacements = replacements
    }

    /// Those on lines up to `line` not handed out yet.
    mutating func through(line: Int) -> [Unicode.Scalar] {
        var found: [Unicode.Scalar] = []
        while next < replacements.count, replacements[next].line <= line {
            found.append(replacements[next].scalar)
            next += 1
        }
        return found
    }
}

/// An entry (or a stray line) and the line it started on, so entries found at different
/// times can be put in file order.
struct LogicalLine {
    let line: Int
    var text: [UInt8]
}

extension RepairNotice {
    /// The notice for the characters one part of the file had replaced, if any.
    static func replaced(_ scalars: [Unicode.Scalar]) -> [RepairNotice] {
        scalars.isEmpty ? [] : [.replacedCharacters(CharacterPolicy.distinct(scalars))]
    }

    /// The notice for the front matter's `format` (§1.5), if it isn't the current one.
    static func format(_ declared: Int?) -> [RepairNotice] {
        guard let declared else { return [.missingFormat] }
        return declared == FormatVersion.current.number ? [] : [.otherFormat(declared)]
    }
}
