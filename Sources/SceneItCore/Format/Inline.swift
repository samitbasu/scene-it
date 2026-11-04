/// Styles as a bit set, one byte per character while parsing.
struct StyleBits: OptionSet, Hashable {
    let rawValue: UInt8

    static let bold = StyleBits(rawValue: 1)
    static let italic = StyleBits(rawValue: 2)
    static let strike = StyleBits(rawValue: 4)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(_ styles: Set<TextStyle>) {
        self = styles.reduce(into: []) { bits, style in bits.insert(Self(style)) }
    }

    init(_ style: TextStyle) {
        switch style {
        case .bold: self = .bold
        case .italic: self = .italic
        case .strike: self = .strike
        }
    }

    var styles: Set<TextStyle> {
        Set(TextStyle.allCases.filter { contains(Self($0)) })
    }

    /// The delimiter that toggles the style (§3.4).
    var delimiter: String {
        switch self {
        case .bold: "**"
        case .italic: "*"
        default: "~~"
        }
    }
}

/// One paragraph's characters and the styles each has.
struct StyledText: Equatable {
    var text: [UInt8] = []
    var styles: [StyleBits] = []

    /// Book format §1.2 step 7, once the markup is read: each character outside printable
    /// ASCII spelled by the table in the styles it was read with, so what it becomes (`*`
    /// for a bullet, `~` for a small tilde) is text, never markup.
    func transliterated() -> StyledText {
        guard !text.allSatisfy({ (0x20...0x7E).contains($0) }) else { return self }
        var result = StyledText()
        var offset = 0
        for scalar in String(decoding: text, as: UTF8.self).unicodeScalars {
            let ascii = CharacterPolicy.transliterated(Array(scalar.utf8))
            result.text += ascii
            result.styles += repeatElement(styles[min(offset, styles.count - 1)], count: ascii.count)
            offset += scalar.utf8.count
        }
        return result
    }
}

/// Book format §3: paragraphs and inline markup, read and written.
enum Inline {
    /// Reads a paragraph's trimmed lines (§3.1, §3.3, §3.4). The caller has already
    /// recognized an empty paragraph (`<br>`).
    static func read(_ lines: [[UInt8]]) -> StyledText {
        if !lines.contains(where: hasMarkup) {
            let text = Array(lines.joined(separator: [Lexical.space]))
            return StyledText(text: text, styles: Array(repeating: [], count: text.count)).transliterated()
        }
        var characters: [UInt8] = []
        var escaped: [Bool] = []
        for (index, line) in lines.enumerated() {
            if index > 0 {
                characters.append(Lexical.space)
                escaped.append(false)
            }
            var position = 0
            while position < line.count {
                let byte = line[position]
                if byte == Lexical.backslash, position + 1 < line.count,
                    Lexical.isEscapable(line[position + 1])
                {
                    characters.append(line[position + 1])
                    escaped.append(true)
                    position += 2
                } else {
                    characters.append(byte)
                    escaped.append(byte == Lexical.backslash)
                    position += 1
                }
            }
        }
        return styled(characters, escaped).transliterated()
    }

    /// Whether a line holds anything §3.3–§3.4 treat specially; most prose doesn't.
    private static func hasMarkup(_ line: [UInt8]) -> Bool {
        line.withUnsafeBufferPointer { bytes in
            bytes.contains { $0 == Lexical.star || $0 == Lexical.tilde || $0 == Lexical.backslash }
        }
    }

    /// A maximal run of unescaped `*` or `~` (§3.4 step 1) and the toggles it stands for.
    private struct DelimiterRun {
        let range: Range<Int>
        let delimiter: UInt8
        let freeStanding: Bool

        /// Step 3: a `*` run is ⌊n/2⌋ bold toggles then, if n is odd, an italic one; a `~`
        /// run is ⌊n/2⌋ strike toggles then, if n is odd, a literal `~`.
        var pairs: StyleBits { delimiter == Lexical.star ? .bold : .strike }
        var pairCount: Int { freeStanding ? 0 : range.count / 2 }
        var hasItalic: Bool { !freeStanding && delimiter == Lexical.star && range.count % 2 == 1 }
    }

    private static func delimiterRuns(_ characters: [UInt8], _ escaped: [Bool]) -> [DelimiterRun] {
        func isWhitespace(_ index: Int) -> Bool {
            characters[index] == Lexical.space && !escaped[index]
        }
        var runs: [DelimiterRun] = []
        var index = 0
        while index < characters.count {
            let delimiter = characters[index]
            guard !escaped[index], delimiter == Lexical.star || delimiter == Lexical.tilde else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, characters[end] == delimiter, !escaped[end] {
                end += 1
            }
            let freeStanding =
                (index == 0 || isWhitespace(index - 1)) && (end == characters.count || isWhitespace(end))
            runs.append(DelimiterRun(range: index..<end, delimiter: delimiter, freeStanding: freeStanding))
            index = end
        }
        return runs
    }

    /// Steps 2–5: free-standing runs and each style's last toggle, if unbalanced, are
    /// literal; every other toggle flips its style for what follows.
    private static func styled(_ characters: [UInt8], _ escaped: [Bool]) -> StyledText {
        let runs = delimiterRuns(characters, escaped)
        var counts: [StyleBits: Int] = [:]
        var lastRun: [StyleBits: Int] = [:]
        for (number, run) in runs.enumerated() {
            if run.pairCount > 0 {
                counts[run.pairs, default: 0] += run.pairCount
                lastRun[run.pairs] = number
            }
            if run.hasItalic {
                counts[.italic, default: 0] += 1
                lastRun[.italic] = number
            }
        }
        func holdsUnbalancedLastToggle(_ style: StyleBits, _ number: Int) -> Bool {
            lastRun[style] == number && counts[style, default: 0] % 2 == 1
        }
        var result = StyledText()
        result.text.reserveCapacity(characters.count)
        result.styles.reserveCapacity(characters.count)
        var styles: StyleBits = []
        func emit(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                result.text.append(byte)
                result.styles.append(styles)
            }
        }
        var nextRun = 0
        var index = 0
        while index < characters.count {
            guard nextRun < runs.count, runs[nextRun].range.lowerBound == index else {
                result.text.append(characters[index])
                result.styles.append(styles)
                index += 1
                continue
            }
            let run = runs[nextRun]
            if run.freeStanding {
                emit(characters[run.range])
            }
            for pair in 0..<run.pairCount {
                if pair == run.pairCount - 1 && holdsUnbalancedLastToggle(run.pairs, nextRun) {
                    emit(run.pairs.delimiter.utf8)
                } else {
                    styles.formSymmetricDifference(run.pairs)
                }
            }
            if run.hasItalic {
                if holdsUnbalancedLastToggle(.italic, nextRun) {
                    emit(StyleBits.italic.delimiter.utf8)
                } else {
                    styles.formSymmetricDifference(.italic)
                }
            } else if !run.freeStanding && run.range.count % 2 == 1 {
                emit([Lexical.tilde])
            }
            index = run.range.upperBound
            nextRun += 1
        }
        return result
    }

    static func isEmptyParagraphMarker(_ line: [UInt8]) -> Bool {
        let lowered = Lexical.lowercased(line)
        return emptyParagraphMarkers.contains(lowered)
    }

    private static let emptyParagraphMarkers: Set<[UInt8]> = [
        Array("<br>".utf8), Array("<br/>".utf8), Array("<br />".utf8),
    ]

    /// The text of a heading's title: §3's reading with the styles dropped (§2.1).
    static func readTitle(_ name: ArraySlice<UInt8>) -> String {
        Lexical.string(read([Lexical.trim(name)]).text)
    }

    // MARK: Writing

    /// A paragraph as one line (§3.5).
    static func write(_ paragraph: Paragraph) -> String {
        guard !paragraph.runs.isEmpty else { return "<br>" }
        let count = paragraph.runs.reduce(0) { $0 + $1.text.unicodeScalars.count }
        var line = WrittenLine(capacity: count + count / 8)
        var position = 0
        var current: StyleBits = []
        var previousWasSpace = false
        var delimiterFollowedSpace = false
        func transition(to next: StyleBits) {
            let delimiters = Self.delimiters(from: current, to: next)
            current = next
            guard !delimiters.isEmpty else { return }
            delimiterFollowedSpace = line.bytes.isEmpty || previousWasSpace
            line.append(delimiters)
            previousWasSpace = false
        }
        for run in paragraph.runs {
            transition(to: StyleBits(run.styles))
            for scalar in run.text.unicodeScalars {
                let edge = position == 0 || position == count - 1
                append(scalar, to: &line, spaces: edge || delimiterFollowedSpace ? .escaped : .plain)
                previousWasSpace = scalar == " "
                delimiterFollowedSpace = false
                position += 1
            }
        }
        transition(to: [])
        let written = line.string
        return needsLineStartEscape(line.bytes) ? "\\" + written : written
    }

    /// A title, for a `## ` heading: characters escaped as in a paragraph, no delimiters.
    static func writeTitle(_ title: String) -> String {
        var line = WrittenLine(capacity: title.utf8.count)
        let count = title.unicodeScalars.count
        for (position, scalar) in title.unicodeScalars.enumerated() {
            append(scalar, to: &line, spaces: position == 0 || position == count - 1 ? .escaped : .plain)
        }
        return line.string
    }

    private static func append(
        _ scalar: Unicode.Scalar, to line: inout WrittenLine, spaces: SpaceWriting
    ) {
        switch scalar {
        case "\\", "*", "_", "~":
            line.append("\\")
        case " " where spaces == .escaped:
            line.append("\\")
        default: break
        }
        line.append(scalar)
    }

    private enum SpaceWriting {
        /// `\␠`, so trimming and §3.4's free-standing rule leave it alone.
        case escaped
        case plain
    }

    /// Closing delimiters (strike, italic, bold), then opening ones (bold, italic, strike).
    private static func delimiters(from current: StyleBits, to next: StyleBits) -> String {
        let closing = current.subtracting(next)
        let opening = next.subtracting(current)
        let closed = [StyleBits.strike, .italic, .bold].filter(closing.contains).map(\.delimiter)
        let opened = [StyleBits.bold, .italic, .strike].filter(opening.contains).map(\.delimiter)
        return (closed + opened).joined()
    }

    private static func needsLineStartEscape(_ line: [UInt8]) -> Bool {
        line.starts(with: "#".utf8) || line.starts(with: "- ".utf8) || line.starts(with: "---".utf8)
            || line.elementsEqual("-".utf8) || (line.count <= 6 && isEmptyParagraphMarker(line))
    }
}
