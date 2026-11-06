/// `BookFormat.serialize`: the canonical form of book format §7.1. Total: it writes any
/// book, and a book that breaks the model's invariants (§7.5) shows up as a failed
/// verification, never as a crash.
enum BookSerializer {
    static func text(of book: Book) -> String {
        var blocks = [frontMatter(book.title)]
        blocks += unparsed(book.errors)
        for part in FilePart.allCases {
            let scenes = book[keyPath: part.scenes]
            if let heading = part.heading, !scenes.isEmpty {
                blocks.append("# " + heading)
            }
            for scene in scenes {
                blocks += self.blocks(scene)
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func frontMatter(_ title: String) -> String {
        frontMatter(fields: frontMatterFields(title))
    }

    static func frontMatter(fields: [String]) -> String {
        (["---"] + fields + ["---"]).joined(separator: "\n")
    }

    static func frontMatterFields(_ title: String) -> [String] {
        [keyValue("title", FieldEscaping.freeText.escape(title)), "format: \(FormatVersion.current)"]
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

    /// The scene's blocks; the first is its heading and metadata lines.
    static func blocks(_ scene: BookScene) -> [String] {
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
        let anchors = body.commentRanges()
        blocks += section(
            "### Comments",
            scene.comments.map { comment($0, anchors[$0.id, default: []], body) })
        blocks += section("### Marks", marks(body, notes))
        blocks += unparsed(scene.errors)
        return blocks
    }

    /// §4.4, §4.5. A comment covers the body alone (ADR 0035).
    private static func comment(_ comment: Comment, _ ranges: [Range<Int>], _ body: WrittenText) -> String {
        let fields = [comment.id.rawValue, comment.color.rawValue, comment.created.description]
        let anchor: [String]
        if ranges.isEmpty {
            anchor = ["detached"]
        } else {
            anchor = [
                ranges.map { range(.body, $0) }.joined(separator: ", "),
                ranges.map(body.quote).joined(separator: ", "),
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

extension WrittenText {
    /// §4.3.
    fileprivate func quote(_ range: Range<Int>) -> String {
        "\"" + FieldEscaping.quoted.escape(text(range)) + "\""
    }
}
