/// `BookFormat.serialize`: the canonical form of book format §7.1. Total: it writes any
/// book, and a book that breaks the model's invariants (§7.5) shows up as a failed
/// verification, never as a crash.
enum BookSerializer {
    static func text(of book: Book) -> String {
        var blocks = [frontMatter(book.title)]
        blocks += unparsed(book.errors)
        for scene in book.scenes {
            blocks += self.blocks(scene)
        }
        if !book.boneyard.isEmpty {
            blocks.append("# Boneyard")
            for scene in book.boneyard {
                blocks += self.blocks(scene)
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func frontMatter(_ title: String) -> String {
        "---\n" + keyValue("title", FieldEscaping.freeText.escape(title))
            + "\nformat: \(FormatVersion.current)\n---"
    }

    private static func keyValue(_ key: String, _ value: String) -> String {
        value.isEmpty ? key + ":" : key + ": " + value
    }

    /// An `### Unparsed` block (§5.1), or none for no entries.
    static func unparsed(_ entries: [ErrorEntry]) -> [String] {
        section("### Unparsed", entries.map { "- " + $0.description })
    }

    /// §2.2's `tags:` line, for at least one tag.
    static func tagsLine(_ tags: [String]) -> String {
        "tags: " + tags.map(FieldEscaping.tag.escape).joined(separator: ", ")
    }

    private static func section(_ heading: String, _ lines: [String]) -> [String] {
        lines.isEmpty ? [] : [([heading] + lines).joined(separator: "\n")]
    }

    private static func blocks(_ scene: BookScene) -> [String] {
        var header = [
            scene.title.text.isEmpty ? "##" : "## " + Inline.writeTitle(scene.title.text),
            "id: \(scene.id)",
            "modified: \(scene.modified)",
        ]
        if !scene.tags.isEmpty {
            header.append(tagsLine(scene.tags))
        }
        var blocks = [header.joined(separator: "\n")]
        blocks += scene.body.map(Inline.write)
        for (index, paragraph) in scene.notes.enumerated() {
            blocks.append((index == 0 ? "### Notes\n" : "") + Inline.write(paragraph))
        }
        let body = WrittenText(scene.body)
        let notes = WrittenText(scene.notes)
        let anchors = (body: body.commentRanges(), notes: notes.commentRanges())
        blocks += section(
            "### Comments",
            scene.comments.map { comment in
                let ranges =
                    anchors.body[comment.id, default: []].map { (TextPart.body, $0) }
                    + anchors.notes[comment.id, default: []].map { (TextPart.notes, $0) }
                return self.comment(comment, ranges, body, notes)
            })
        blocks += section("### Marks", marks(body, notes))
        blocks += unparsed(scene.errors)
        return blocks
    }

    /// §4.4, §4.5.
    private static func comment(
        _ comment: Comment, _ ranges: [(TextPart, Range<Int>)], _ body: WrittenText, _ notes: WrittenText
    ) -> String {
        let fields = [comment.id.rawValue, comment.color.rawValue, comment.created.description]
        let anchor: [String]
        if ranges.isEmpty {
            anchor = ["detached"]
        } else {
            anchor = [
                ranges.map { range($0.0, $0.1) }.joined(separator: ", "),
                ranges.map { ($0.0 == .body ? body : notes).quote($0.1) }.joined(separator: ", "),
            ]
        }
        let text = FieldEscaping.freeText.escape(comment.text)
        return "- " + (fields + anchor).joined(separator: " | ") + (text.isEmpty ? " |" : " | " + text)
    }

    /// §4.6: one entry per maximal stretch of a color or highlight, sorted.
    private static func marks(_ body: WrittenText, _ notes: WrittenText) -> [String] {
        struct Mark {
            let part: TextPart
            let range: Range<Int>
            let isHighlight: Bool
            let line: String
        }
        var marks: [Mark] = []
        for (part, text) in [(TextPart.body, body), (.notes, notes)] {
            for color in TextColor.allCases {
                for range in text.ranges(where: { $0.color == color }) {
                    marks.append(
                        Mark(
                            part: part, range: range, isHighlight: false,
                            line:
                                "- color \(color.rawValue) | \(self.range(part, range)) | \(text.quote(range))"
                        ))
                }
            }
            for highlight in HighlightColor.allCases {
                for range in text.ranges(where: { $0.highlight == highlight }) {
                    marks.append(
                        Mark(
                            part: part, range: range, isHighlight: true,
                            line:
                                "- highlight \(highlight.rawValue) | \(self.range(part, range)) | \(text.quote(range))"
                        ))
                }
            }
        }
        return marks.sorted { first, second in
            (first.part, first.range.lowerBound, first.isHighlight ? 1 : 0)
                < (second.part, second.range.lowerBound, second.isHighlight ? 1 : 0)
        }
        .map(\.line)
    }

    private static func range(_ part: TextPart, _ range: Range<Int>) -> String {
        (part == .notes ? "notes " : "") + "c\(range.lowerBound)-\(range.upperBound)"
    }
}

/// A body or notes as the serializer addresses it: the plain text (§3.6) and where each run
/// sits in it.
private struct WrittenText {
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

    /// §4.3.
    func quote(_ range: Range<Int>) -> String {
        "\"" + FieldEscaping.quoted.escape(String(String.UnicodeScalarView(plain[range]))) + "\""
    }
}
