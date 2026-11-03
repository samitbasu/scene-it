/// What a repair that took effect added to its owner, beyond removing the entry: a comment, a
/// color or highlight over some characters, or a metadata or front-matter value. Undo takes back
/// exactly that, so edits made since (typing, a new title) survive it.
struct RepairEffect: Hashable, Sendable {
    struct Change<Value: Hashable & Sendable>: Hashable, Sendable {
        let before: Value
        let after: Value
    }

    /// The colors and highlights of a stretch of a body or notes, before and after.
    struct Colors: Hashable, Sendable {
        let part: TextPart
        let start: Int
        let text: [Unicode.Scalar]
        let before: [CharacterColor]
        let after: [CharacterColor]
    }

    var title: Change<String>?
    var id: Change<SceneID>?
    var modified: Change<Timestamp>?
    var tags: Change<[String]>?
    var comments: [CommentID] = []
    var colors: [Colors] = []

    init(from old: BookPart, to new: BookPart) {
        switch (old, new) {
        case (.header(let before, _), .header(let after, _)):
            title = Self.change(before, after)
        case (.scene(let before), .scene(let after)):
            id = Self.change(before.id, after.id)
            modified = Self.change(before.modified, after.modified)
            tags = Self.change(before.tags, after.tags)
            let had = Set(before.comments.map(\.id))
            comments = after.comments.map(\.id).filter { !had.contains($0) }
            colors = [
                Self.colors(.body, before.body, after.body), Self.colors(.notes, before.notes, after.notes),
            ].compactMap { $0 }
        case (.header, .scene), (.scene, .header):
            break
        }
    }

    /// `part` without what the repair added. A value is put back only while it's still the one
    /// the repair set, and colors only while their characters still read as they did.
    func undone(in part: BookPart) -> BookPart {
        switch part {
        case .header(var title, let errors):
            if let change = self.title, title == change.after { title = change.before }
            return .header(title: title, errors: errors)
        case .scene(var scene):
            if let id, scene.id == id.after { scene.id = id.before }
            if let modified, scene.modified == modified.after { scene.modified = modified.before }
            if let tags, scene.tags == tags.after { scene.tags = tags.before }
            if !comments.isEmpty {
                let added = Set(comments)
                scene.comments.removeAll { added.contains($0.id) }
                scene.body = Self.removing(added, from: scene.body)
                scene.notes = Self.removing(added, from: scene.notes)
            }
            for change in colors {
                switch change.part {
                case .body: scene.body = Self.restoring(change, in: scene.body)
                case .notes: scene.notes = Self.restoring(change, in: scene.notes)
                }
            }
            return .scene(scene)
        }
    }

    private static func change<Value>(_ before: Value, _ after: Value) -> Change<Value>? {
        before == after ? nil : Change(before: before, after: after)
    }

    /// The stretch from the first to the last character whose color or highlight differs.
    private static func colors(_ part: TextPart, _ before: [Paragraph], _ after: [Paragraph]) -> Colors? {
        let (old, new) = (CharacterRuns(before), CharacterRuns(after))
        guard old.text == new.text,
            let first = old.text.indices.first(where: { old.colors[$0] != new.colors[$0] }),
            let last = old.text.indices.last(where: { old.colors[$0] != new.colors[$0] })
        else { return nil }
        return Colors(
            part: part, start: first, text: Array(old.text[first...last]),
            before: Array(old.colors[first...last]), after: Array(new.colors[first...last]))
    }

    private static func restoring(_ change: Colors, in paragraphs: [Paragraph]) -> [Paragraph] {
        var runs = CharacterRuns(paragraphs)
        let range = change.start..<change.start + change.text.count
        guard range.upperBound <= runs.text.count, Array(runs.text[range]) == change.text,
            Array(runs.colors[range]) == change.after
        else { return paragraphs }
        runs.colors.replaceSubrange(range, with: change.before)
        return runs.paragraphs
    }

    private static func removing(_ ids: Set<CommentID>, from paragraphs: [Paragraph]) -> [Paragraph] {
        paragraphs.map { paragraph in
            var runs = paragraph.runs
            for index in runs.indices { runs[index].comments.subtract(ids) }
            return Paragraph(runs).withMaximalRuns
        }
    }
}

/// A character's color and highlight.
struct CharacterColor: Hashable, Sendable {
    var color: TextColor?
    var highlight: HighlightColor?
}

/// A body or notes one character at a time, addressed as its plain text is (book format §3.6:
/// paragraphs joined by `\n`, which carries no format).
private struct CharacterRuns {
    private(set) var text: [Unicode.Scalar] = []
    var colors: [CharacterColor] = []
    private var formats: [Run?] = []
    private let paragraphCount: Int

    init(_ paragraphs: [Paragraph]) {
        paragraphCount = paragraphs.count
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 {
                text.append("\n")
                colors.append(CharacterColor())
                formats.append(nil)
            }
            for run in paragraph.runs {
                for scalar in run.text.unicodeScalars {
                    text.append(scalar)
                    colors.append(CharacterColor(color: run.color, highlight: run.highlight))
                    formats.append(run)
                }
            }
        }
    }

    var paragraphs: [Paragraph] {
        var paragraphs: [Paragraph] = []
        var runs: [Run] = []
        for index in text.indices {
            guard let format = formats[index] else {
                paragraphs.append(Paragraph(runs).withMaximalRuns)
                runs = []
                continue
            }
            runs.append(
                Run(
                    admitted: String(Character(text[index])), styles: format.styles,
                    color: colors[index].color,
                    highlight: colors[index].highlight, comments: format.comments))
        }
        if paragraphCount > 0 { paragraphs.append(Paragraph(runs).withMaximalRuns) }
        return paragraphs
    }
}
