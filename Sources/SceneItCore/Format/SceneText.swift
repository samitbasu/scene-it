/// A range in a scene's body or notes plain text, start inclusive, end exclusive (§4.2).
struct TextRange: Hashable {
    let part: TextPart
    let offsets: Range<Int>
}

/// A scene's body or notes while it's parsed: the plain text (§3.6) and every character's
/// styles, color and highlight, plus the comments' ranges, which become runs at the end.
struct SceneText {
    private(set) var text: [UInt8] = []
    private var styles: [StyleBits] = []
    private var colors: [UInt8] = []
    private var highlights: [UInt8] = []
    private var paragraphs: [Range<Int>] = []
    /// Each comment's ranges, by the comment's number.
    private var comments: [(comment: Int, range: Range<Int>)] = []

    init(_ paragraphs: [StyledText]) {
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 {
                text.append(Lexical.newline)
                styles.append([])
            }
            self.paragraphs.append(text.count..<text.count + paragraph.text.count)
            text += paragraph.text
            styles += paragraph.styles
        }
        colors = Array(repeating: 0, count: text.count)
        highlights = Array(repeating: 0, count: text.count)
    }

    /// §4.2's validity: in bounds, not empty or backwards, and covering more than `\n`.
    func isValid(_ range: Range<Int>) -> Bool {
        range.lowerBound >= 0 && range.upperBound <= text.count && !range.isEmpty
            && text[range].contains { $0 != Lexical.newline }
    }

    mutating func setColor(_ color: TextColor?, in range: Range<Int>) {
        set(&colors, color.map { Self.code(of: $0, in: TextColor.allCases) } ?? 0, in: range)
    }

    mutating func setHighlight(_ highlight: HighlightColor, in range: Range<Int>) {
        set(&highlights, Self.code(of: highlight, in: HighlightColor.allCases), in: range)
    }

    /// Covers `range` with the comment numbered `comment`. Paragraph breaks inside it carry
    /// nothing, since no run holds them.
    mutating func addComment(_ comment: Int, in range: Range<Int>) {
        comments.append((comment, range))
    }

    /// The paragraphs as maximal runs; `comments` maps a comment's number to its id.
    func paragraphs(comments ids: [CommentID]) -> [Paragraph] {
        let (slots, sets) = commentSlots()
        var formats = [UInt64](repeating: 0, count: text.count)
        formats.withUnsafeMutableBufferPointer { formats in
            for index in formats.indices {
                formats[index] =
                    UInt64(styles[index].rawValue) | UInt64(colors[index]) << 8 | UInt64(highlights[index])
                    << 16
                    | UInt64(slots[index]) << 32
            }
        }
        return paragraphs.map { range in
            var runs: [Run] = []
            var start = range.lowerBound
            while start < range.upperBound {
                var end = start + 1
                while end < range.upperBound, formats[end] == formats[start] {
                    end += 1
                }
                runs.append(
                    Run(
                        admitted: Lexical.string(text[start..<end]),
                        styles: styles[start].styles,
                        color: Self.value(colors[start], in: TextColor.allCases),
                        highlight: Self.value(highlights[start], in: HighlightColor.allCases),
                        comments: Set(sets[Int(slots[start])].map { ids[$0] })))
                start = end
            }
            return Paragraph(runs)
        }
    }

    /// Each character's set of comments, as an index into `sets`, found by sweeping the
    /// ranges' endpoints: the set changes only where a range starts or ends.
    private func commentSlots() -> (slots: [UInt32], sets: [[Int]]) {
        var slots = [UInt32](repeating: 0, count: text.count)
        guard !comments.isEmpty else { return (slots, [[]]) }
        var events: [(offset: Int, comment: Int, delta: Int)] = []
        for (comment, range) in comments {
            events.append((range.lowerBound, comment, 1))
            events.append((range.upperBound, comment, -1))
        }
        events.sort { $0.offset < $1.offset }
        var sets: [[Int]] = [[]]
        var slotOfSet: [[Int]: UInt32] = [[]: 0]
        var active: [Int: Int] = [:]
        var slot: UInt32 = 0
        var next = 0
        for offset in 0..<text.count {
            if next < events.count, events[next].offset <= offset {
                while next < events.count, events[next].offset <= offset {
                    let comment = events[next].comment
                    active[comment, default: 0] += events[next].delta
                    if active[comment] == 0 { active[comment] = nil }
                    next += 1
                }
                let set = active.keys.sorted()
                if let known = slotOfSet[set] {
                    slot = known
                } else {
                    sets.append(set)
                    slot = UInt32(sets.count - 1)
                    slotOfSet[set] = slot
                }
            }
            slots[offset] = slot
        }
        return (slots, sets)
    }

    private func set(_ values: inout [UInt8], _ value: UInt8, in range: Range<Int>) {
        for index in range where text[index] != Lexical.newline {
            values[index] = value
        }
    }

    private static func code<T: Equatable>(of value: T, in all: [T]) -> UInt8 {
        UInt8((all.firstIndex(of: value) ?? 0) + 1)
    }

    private static func value<T>(_ code: UInt8, in all: [T]) -> T? {
        code == 0 ? nil : all[Int(code) - 1]
    }
}
