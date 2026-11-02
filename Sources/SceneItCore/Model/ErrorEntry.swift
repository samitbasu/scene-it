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
/// The payload is one line with no leading or trailing spaces. It's kept verbatim and never
/// re-parsed on load.
public struct ErrorEntry: Hashable, Sendable, CustomStringConvertible {
    public var tag: ErrorTag
    public var payload: String

    public init(_ tag: ErrorTag, _ payload: String) {
        self.tag = tag
        self.payload = payload
    }

    public var description: String {
        payload.isEmpty ? "[\(tag.rawValue)]" : "[\(tag.rawValue)] \(payload)"
    }
}
