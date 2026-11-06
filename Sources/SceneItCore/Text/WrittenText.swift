/// A body or notes as `book.md` addresses it (book format §3.6): the plain text and where each
/// run sits in it. The serializer writes comments' and marks' ranges from it, and the comments
/// panel quotes comments from it, so the two can't disagree on where a comment is.
struct WrittenText {
    private let plain: [Unicode.Scalar]
    /// In text order; consecutive runs are separated only by paragraph breaks, if anything.
    private let runs: [(range: Range<Int>, run: Run)]

    init(_ paragraphs: [Paragraph]) {
        var plain: [Unicode.Scalar] = []
        var runs: [(Range<Int>, Run)] = []
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { plain.append("\n") }
            for run in paragraph.runs {
                let start = plain.count
                plain += run.text.unicodeScalars
                runs.append((start..<plain.count, run))
            }
        }
        self.plain = plain
        self.runs = runs
    }

    /// The maximal ranges of runs satisfying `predicate`. Two such runs with only
    /// paragraph breaks between them share a range (§4.2).
    func ranges(where predicate: (Run) -> Bool) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var open: Range<Int>?
        for (range, run) in runs where !range.isEmpty {
            if predicate(run) {
                open = open.map { $0.lowerBound..<range.upperBound } ?? range
            } else if let finished = open {
                ranges.append(finished)
                open = nil
            }
        }
        if let open { ranges.append(open) }
        return ranges
    }

    /// Every comment's maximal ranges (as `ranges(where:)` would find them), in one pass.
    func commentRanges() -> [CommentID: [Range<Int>]] {
        var ranges: [CommentID: [Range<Int>]] = [:]
        var lastRun: [CommentID: Int] = [:]
        var number = 0
        for (range, run) in runs where !range.isEmpty {
            for id in run.comments {
                if lastRun[id] == number - 1, let open = ranges[id]?.popLast() {
                    ranges[id, default: []].append(open.lowerBound..<range.upperBound)
                } else {
                    ranges[id, default: []].append(range)
                }
                lastRun[id] = number
            }
            number += 1
        }
        return ranges
    }

    /// The plain text in `range`, its paragraph breaks as `\n`.
    func text(_ range: Range<Int>) -> String {
        String(String.UnicodeScalarView(plain[range]))
    }
}
