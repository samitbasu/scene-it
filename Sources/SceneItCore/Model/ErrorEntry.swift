/// Where an error entry came from (book format §5.1). The raw value is the tag as written.
public enum ErrorTag: String, CaseIterable, Hashable, Sendable {
    case frontMatter = "front matter"
    case metadata
    case comments
    case marks
    case line
    case notice
}

/// A line the parser couldn't understand, or a note about a repair it made: one row of the
/// Errors tab, written as `- [<tag>] <payload>` in an `### Unparsed` section.
///
/// The payload is kept verbatim and never re-parsed on load.
public struct ErrorEntry: Hashable, Sendable, CustomStringConvertible {
    public var tag: ErrorTag
    /// One admitted line, trimmed as book format §1.3 trims a line: no leading spaces, no
    /// trailing space unless it's escaped, and never an odd run of `\` at the end (one
    /// gets its space back). That's exactly what reading `- [<tag>] <payload>` gives, so
    /// any payload is written and read back unchanged. Every assignment applies it.
    public var payload: String {
        didSet { payload = Self.normalized(payload) }
    }

    public init(_ tag: ErrorTag, _ payload: String) {
        self.tag = tag
        self.payload = Self.normalized(payload)
    }

    public var description: String {
        payload.isEmpty ? "[\(tag.rawValue)]" : "[\(tag.rawValue)] \(payload)"
    }

    private static func normalized(_ payload: String) -> String {
        let line = Latin1.bytes(CharacterPolicy.admittedLine(payload))
        return Latin1.string(Lexical.trim(line[...])[...])
    }
}
