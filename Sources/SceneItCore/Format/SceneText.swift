/// Which plain text a range addresses (§3.6).
enum TextPart: Hashable, Comparable {
    case body, notes
}

/// A range in a scene's body or notes plain text, start inclusive, end exclusive (§4.2).
struct TextRange: Hashable {
    let part: TextPart
    let offsets: Range<Int>
}

/// A scene's body or notes while it's parsed: the plain text (§3.6) and every character's
/// styles, color, highlight and comments, which marks and comments are applied to before
/// it becomes runs.
struct SceneText {
    private(set) var text: [UInt8] = []
    private var styles: [StyleBits] = []
    private var colors: [UInt8] = []
    private var highlights: [UInt8] = []
    private var paragraphs: [Range<Int>] = []
    /// Each character's comments, as an index into `commentSets`; 0 is none.
    private var commentSlots: [Int32] = []
    private var commentSets: [[Int]] = [[]]
    private var commentSetIndex: [[Int]: Int32] = [[]: 0]

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
        commentSlots = Array(repeating: 0, count: text.count)
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

    /// Covers `range` with the comment numbered `comment`; comments are added in ascending order.
    mutating func addComment(_ comment: Int, in range: Range<Int>) {
        for index in range where text[index] != Lexical.newline {
            let current = commentSets[Int(commentSlots[index])]
            guard current.last != comment else { continue }
            let next = current + [comment]
            if let slot = commentSetIndex[next] {
                commentSlots[index] = slot
            } else {
                let slot = Int32(commentSets.count)
                commentSets.append(next)
                commentSetIndex[next] = slot
                commentSlots[index] = slot
            }
        }
    }

    /// The paragraphs as maximal runs; `comments` maps a comment's number to its id.
    func paragraphs(comments: [CommentID]) -> [Paragraph] {
        var formats = [UInt64](repeating: 0, count: text.count)
        formats.withUnsafeMutableBufferPointer { formats in
            for index in formats.indices {
                formats[index] =
                    UInt64(styles[index].rawValue) | UInt64(colors[index]) << 8 | UInt64(highlights[index])
                    << 16
                    | UInt64(UInt32(bitPattern: commentSlots[index])) << 32
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
                        Lexical.string(text[start..<end]),
                        styles: styles[start].styles,
                        color: Self.value(colors[start], in: TextColor.allCases),
                        highlight: Self.value(highlights[start], in: HighlightColor.allCases),
                        comments: Set(commentSets[Int(commentSlots[start])].map { comments[$0] })))
                start = end
            }
            return Paragraph(runs)
        }
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
