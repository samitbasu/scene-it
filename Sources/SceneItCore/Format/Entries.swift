/// Why a comment or mark entry is an error (book format §4.8, E1–E10).
enum EntryProblem: String, Error, Hashable, CaseIterable {
    case strayLine = "E1"
    case fields = "E2"
    case commentID = "E3"
    case paletteName = "E4"
    case timestamp = "E5"
    case rangeSyntax = "E6"
    case rangeBounds = "E7"
    case quoteSyntax = "E8"
    case quoteMismatch = "E9"
    case leftover = "E10"
}

/// What a comment or mark entry is checked against: the scene's plain texts.
struct EntryContext {
    let body: SceneText
    let notes: SceneText
    /// The ids of the comments already read in this scene.
    var commentIDs: Set<CommentID>

    func text(_ part: TextPart) -> SceneText {
        part == .body ? body : notes
    }
}

/// Whether an error entry was already in the file, in an `### Unparsed` section, or this
/// parse made it (ADR 0024).
enum EntryOrigin {
    case preserved, new
}

struct ParsedComment: Equatable {
    let comment: Comment
    /// Empty for a detached comment.
    let ranges: [TextRange]
}

enum MarkKind: Equatable {
    /// `nil` is `color black`, which clears the color.
    case color(TextColor?)
    case highlight(HighlightColor)
}

struct ParsedMark: Equatable {
    let kind: MarkKind
    let ranges: [TextRange]
}

/// Comment, mark and Unparsed entries (book format §4, §5.1). Each reads an entry's logical
/// line (trimmed, continuations joined) and either accepts it or names the rule it breaks.
enum Entries {
    static func comment(_ line: [UInt8], in context: EntryContext) -> Result<ParsedComment, EntryProblem> {
        var fields = FieldReader(Lexical.entryContent(line))
        guard let id = fields.next(), let color = fields.next(), let created = fields.next(),
            let rangeField = fields.next(), ![id, color, created, rangeField].contains(where: \.isEmpty)
        else { return .failure(.fields) }
        let commentID = CommentID(rawValue: Lexical.string(id))
        guard Lexical.isValidID(id), !context.commentIDs.contains(commentID) else {
            return .failure(.commentID)
        }
        guard let palette = paletteColor(color) else { return .failure(.paletteName) }
        guard let timestamp = Timestamp(Lexical.string(created)) else { return .failure(.timestamp) }
        func made(_ text: ArraySlice<UInt8>, _ ranges: [TextRange]) -> Result<ParsedComment, EntryProblem> {
            let text = Lexical.string(Lexical.fieldUnescaped(Lexical.withoutLeadingSpaces(text)))
            return .success(
                ParsedComment(
                    comment: Comment(id: commentID, color: palette, text: text, created: timestamp),
                    ranges: ranges))
        }
        if Lexical.equalsIgnoringCase(rangeField, "detached") {
            return made(fields.rest, [])
        }
        guard let ranges = ranges(rangeField) else { return .failure(.rangeSyntax) }
        let quotes: [[UInt8]]
        switch fields.quotes() {
        case .success(let read): quotes = read
        case .failure(let problem): return .failure(problem)
        }
        guard fields.skipSeparator() else { return .failure(.fields) }
        if let problem = check(ranges, quotes, in: context) { return .failure(problem) }
        return made(fields.rest, ranges)
    }

    static func mark(_ line: [UInt8], in context: EntryContext) -> Result<ParsedMark, EntryProblem> {
        var fields = FieldReader(Lexical.entryContent(line))
        guard let kindField = fields.next(), let rangeField = fields.next() else { return .failure(.fields) }
        let words = kindField.split(separator: Lexical.space)
        guard words.count == 2 else { return .failure(.fields) }
        guard let name = paletteColor(words[1]) else { return .failure(.paletteName) }
        let kind: MarkKind
        if Lexical.equalsIgnoringCase(words[0], "color") {
            kind = .color(TextColor(name))
        } else if Lexical.equalsIgnoringCase(words[0], "highlight"),
            let highlight = HighlightColor(rawValue: name.rawValue)
        {
            kind = .highlight(highlight)
        } else {
            return .failure(.paletteName)
        }
        guard let ranges = ranges(rangeField) else { return .failure(.rangeSyntax) }
        let quotes: [[UInt8]]
        switch fields.quotes() {
        case .success(let read): quotes = read
        case .failure(let problem): return .failure(problem)
        }
        guard Lexical.strippingSpaces(fields.rest).isEmpty else { return .failure(.leftover) }
        if let problem = check(ranges, quotes, in: context) { return .failure(problem) }
        return .success(ParsedMark(kind: kind, ranges: ranges))
    }

    /// An `### Unparsed` entry line (§5.1): `- [<tag>] <payload>`, which the file already
    /// held, or else the whole line kept as a new `[line]` entry.
    static func unparsed(_ line: [UInt8]) -> (entry: ErrorEntry, origin: EntryOrigin) {
        let content = Lexical.entryContent(line)
        if content.first == Lexical.openBracket, let close = content.firstIndex(of: Lexical.closeBracket),
            let tag = ErrorTag.allCases.first(where: {
                Lexical.equalsIgnoringCase(content[(content.startIndex + 1)..<close], $0.rawValue)
            }),
            close + 1 == content.endIndex || content[close + 1] == Lexical.space
        {
            return (
                ErrorEntry(tag, Lexical.string(Lexical.withoutLeadingSpaces(content[(close + 1)...]))),
                .preserved
            )
        }
        return (ErrorEntry(.line, Lexical.string(line)), .new)
    }

    /// Palette names are case-insensitive, and `grey` is `gray`.
    static func paletteColor(_ name: some Collection<UInt8>) -> PaletteColor? {
        let lowered = String(decoding: Lexical.lowercased(name), as: UTF8.self)
        return lowered == "grey" ? .gray : PaletteColor(rawValue: lowered)
    }

    /// A range list (§4.2): `c<start>-<end>` or `notes c<start>-<end>`, separated by commas.
    static func ranges(_ field: ArraySlice<UInt8>) -> [TextRange]? {
        var result: [TextRange] = []
        for item in field.split(separator: Lexical.comma, omittingEmptySubsequences: false) {
            guard let range = range(Lexical.strippingSpaces(item)) else { return nil }
            result.append(range)
        }
        return result
    }

    private static func range(_ item: ArraySlice<UInt8>) -> TextRange? {
        var rest = item
        var part = TextPart.body
        if rest.count > 5, Lexical.equalsIgnoringCase(rest.prefix(5), "notes"),
            rest[rest.startIndex + 5] == Lexical.space
        {
            part = .notes
            rest = Lexical.withoutLeadingSpaces(rest.dropFirst(5))
        }
        guard let first = rest.first, first == UInt8(ascii: "c") || first == UInt8(ascii: "C") else {
            return nil
        }
        let numbers = rest.dropFirst().split(separator: Lexical.dash, omittingEmptySubsequences: false)
        guard numbers.count == 2, let start = number(numbers[0]), let end = number(numbers[1]) else {
            return nil
        }
        // A backwards range (`c19-13`) is kept as an empty one, which is never valid (E7).
        return TextRange(part: part, offsets: start..<max(start, end))
    }

    /// A decimal number, saturating rather than overflowing.
    private static func number(_ digits: ArraySlice<UInt8>) -> Int? {
        guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return digits.reduce(0) { value, digit in
            let (product, overflowed) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflowedAgain) = product.addingReportingOverflow(Int(digit - 0x30))
            return overflowed || overflowedAgain ? Int.max : sum
        }
    }

    private static func check(_ ranges: [TextRange], _ quotes: [[UInt8]], in context: EntryContext)
        -> EntryProblem?
    {
        guard quotes.count == ranges.count else { return .quoteSyntax }
        guard ranges.allSatisfy({ context.text($0.part).isValid($0.offsets) }) else { return .rangeBounds }
        for (range, quote) in zip(ranges, quotes)
        where !context.text(range.part).text[range.offsets].elementsEqual(quote) {
            return .quoteMismatch
        }
        return nil
    }
}

/// Reads an entry's `|`-separated fields left to right.
private struct FieldReader {
    private let bytes: ArraySlice<UInt8>
    private var position: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        position = bytes.startIndex
    }

    /// Everything not yet read.
    var rest: ArraySlice<UInt8> {
        bytes[position...]
    }

    /// The next field, spaces stripped, up to a `|`; `nil` if there's no `|` left.
    mutating func next() -> ArraySlice<UInt8>? {
        guard let bar = bytes[position...].firstIndex(of: Lexical.pipe) else { return nil }
        defer { position = bar + 1 }
        return Lexical.strippingSpaces(bytes[position..<bar])
    }

    /// Consumes spaces and one `|`; `false` if something else comes first.
    mutating func skipSeparator() -> Bool {
        skipSpaces()
        guard position < bytes.endIndex, bytes[position] == Lexical.pipe else { return false }
        position += 1
        return true
    }

    /// A quote list (§4.3): `"…"`, separated by commas.
    mutating func quotes() -> Result<[[UInt8]], EntryProblem> {
        var quotes: [[UInt8]] = []
        repeat {
            skipSpaces()
            guard position < bytes.endIndex, bytes[position] == Lexical.quote else {
                return .failure(.quoteSyntax)
            }
            let start = position + 1
            var end = start
            while end < bytes.endIndex, bytes[end] != Lexical.quote {
                end += bytes[end] == Lexical.backslash ? 2 : 1
            }
            guard end < bytes.endIndex else { return .failure(.quoteSyntax) }
            quotes.append(Lexical.quoteUnescaped(bytes[start..<end]))
            position = end + 1
            skipSpaces()
        } while consume(Lexical.comma)
        return .success(quotes)
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.endIndex, bytes[position] == byte else { return false }
        position += 1
        return true
    }

    private mutating func skipSpaces() {
        while position < bytes.endIndex, bytes[position] == Lexical.space {
            position += 1
        }
    }
}
