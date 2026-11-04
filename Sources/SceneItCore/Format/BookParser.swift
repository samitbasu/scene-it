import Foundation

/// `BookFormat.parse`: a single pass over the file's trimmed lines, with no way to fail.
/// Every line either takes effect or becomes an error entry of the scene (or the book) it
/// was found in, so damage stays where it is.
enum BookParser {
    static func parse(_ bytes: Data, opened: Timestamp, ids: inout some SceneIDSource) -> ParsedBook {
        let decoded = BookTextDecoder.decode(bytes)
        let admitted = CharacterPolicy.fileText(decoded.text)
        let reader = Reader(lines: lines(admitted.bytes), changes: admitted.changes)
        reader.read()
        return reader.finish(windows1252ByteCount: decoded.windows1252ByteCount, opened: opened, ids: &ids)
    }

    /// §1.2 step 6 and §1.3: the text's physical lines, trimmed. A final `\n` ends the last
    /// line rather than starting another.
    static func lines(_ text: [UInt8]) -> [[UInt8]] {
        var lines = text.split(separator: Lexical.newline, omittingEmptySubsequences: false)
        if text.last == Lexical.newline || text.isEmpty {
            lines.removeLast()
        }
        return lines.map(Lexical.trim)
    }
}

private enum SceneSection {
    /// The `key: value` lines directly under the heading.
    case metadata
    case body, notes, comments, marks, unparsed
}

private enum SceneList {
    case story, boneyard
}

private final class SceneDraft {
    let title: String
    var section = SceneSection.metadata
    var metadataKeys: Set<String> = []
    var id: SceneID?
    var modified: Timestamp?
    var tags: [String] = []
    var body: [StyledText] = []
    var notes: [StyledText] = []
    var commentLines: [LogicalLine] = []
    var markLines: [LogicalLine] = []
    var entries: [Positioned] = []
    var changed: [CharacterChange] = []
    let list: SceneList
    var paragraphs: (body: [Paragraph], notes: [Paragraph]) = ([], [])
    var comments: [Comment] = []

    init(title: String, list: SceneList) {
        self.title = title
        self.list = list
    }
}

private final class Reader {
    private let lines: [[UInt8]]
    private var changes: ChangeCursor

    private var bookEntries: [Positioned] = []
    private var bookChanged: [CharacterChange] = []
    private var frontMatterKeys: Set<String> = []
    private var title: String?
    private var format: Int?
    /// Outside any scene, whether the lines are in a book-level `### Unparsed` section.
    private var inBookUnparsed = false
    private var inBoneyard = false
    private var scenes: [SceneDraft] = []
    private var current: SceneDraft?
    private var paragraph: [[UInt8]] = []
    private var entry: LogicalLine?

    init(lines: [[UInt8]], changes: [CharacterChange]) {
        self.lines = lines
        self.changes = ChangeCursor(changes)
    }

    func read() {
        let frontMatter = Lexical.frontMatter(lines)
        for number in frontMatter.lines {
            self.frontMatter(lines[number], number)
        }
        for number in 0..<frontMatter.end {
            bookChanged += changes.through(line: number)
        }
        for number in frontMatter.end..<lines.count {
            process(number)
        }
        endScene()
    }

    // MARK: Front matter (§1.5)

    private func frontMatter(_ line: [UInt8], _ number: Int) {
        guard let (key, value) = Lexical.keyValue(line) else {
            return bookEntry(.frontMatter, line, number, .frontMatter(.notAField))
        }
        guard ["title", "format"].contains(key) else {
            return bookEntry(.frontMatter, line, number, .frontMatter(.unknownKey))
        }
        guard frontMatterKeys.insert(key).inserted else {
            return bookEntry(.frontMatter, line, number, .frontMatter(.repeatedKey))
        }
        let unescaped = Lexical.fieldUnescaped(value)
        if key == "title" {
            title = Lexical.string(unescaped)
        } else if let number = Lexical.formatNumber(unescaped) {
            format = number
        } else {
            bookEntry(.frontMatter, line, number, .frontMatter(.badFormat))
        }
    }

    // MARK: Lines

    private func process(_ number: Int) {
        let line = lines[number]
        let kind = Lexical.kind(of: line)
        let startsAPart: Bool
        switch kind {
        case .heading(2, let name):
            endScene()
            current = SceneDraft(title: Inline.readTitle(name), list: inBoneyard ? .boneyard : .story)
            startsAPart = true
        case .heading(1, let name) where !inBoneyard && Lexical.equalsIgnoringCase(name, "boneyard"):
            endScene()
            inBoneyard = true
            inBookUnparsed = false
            startsAPart = true
        default:
            startsAPart = false
        }
        if let current {
            current.changed += changes.through(line: number)
        } else {
            bookChanged += changes.through(line: number)
        }
        guard !startsAPart else { return }
        switch kind {
        case .blank:
            endParagraph()
            endEntry()
            if current?.section == .metadata { current?.section = .body }
        case .heading(3, let name) where subsection(name) != nil:
            open(subsection(name)!, line, number)
        case .heading:
            endParagraph()
            endEntry()
            if current?.section == .metadata { current?.section = .body }
            record(.line, line, number)
        case .text:
            text(line, number)
        }
    }

    private func subsection(_ name: ArraySlice<UInt8>) -> SceneSection? {
        let names: [(String, SceneSection)] = [
            ("notes", .notes), ("comments", .comments), ("marks", .marks), ("unparsed", .unparsed),
        ]
        return names.first { Lexical.equalsIgnoringCase(name, $0.0) }?.1
    }

    /// A known `###` heading: a subsection of the current scene, or (for Unparsed only) a
    /// book-level section; anywhere else it's not understood.
    private func open(_ section: SceneSection, _ line: [UInt8], _ number: Int) {
        endParagraph()
        endEntry()
        if let current {
            current.section = section
        } else if section == .unparsed {
            inBookUnparsed = true
        } else {
            record(.line, line, number)
        }
    }

    private func text(_ line: [UInt8], _ number: Int) {
        guard let scene = current else {
            if inBookUnparsed {
                entryLine(line, number)
            } else {
                record(.line, line, number)
            }
            return
        }
        if scene.section == .metadata {
            if let (key, value) = Lexical.keyValue(line) {
                return metadata(key, value, line, number)
            }
            scene.section = .body
        }
        switch scene.section {
        case .metadata, .body, .notes:
            paragraph.append(line)
        case .comments, .marks, .unparsed:
            entryLine(line, number)
        }
    }

    /// §4.1: an entry starts with `- `; a line right under an entry continues it; any other
    /// line is stray.
    private func entryLine(_ line: [UInt8], _ number: Int) {
        if Lexical.isEntryStart(line) {
            endEntry()
            entry = LogicalLine(line: number, text: line)
        } else if entry != nil {
            entry?.text += [Lexical.space] + line
        } else {
            switch current?.section {
            case .comments?: record(.comments, line, number, .comment(.strayLine))
            case .marks?: record(.marks, line, number, .mark(.strayLine))
            default: record(.line, line, number)
            }
        }
    }

    private func endEntry() {
        guard let logical = entry else { return }
        entry = nil
        guard let scene = current else {
            let (entry, origin) = Entries.unparsed(logical.text)
            bookEntries.append(Positioned(line: logical.line, entry: entry, origin: origin))
            return
        }
        switch scene.section {
        case .comments: scene.commentLines.append(logical)
        case .marks: scene.markLines.append(logical)
        default:
            let (entry, origin) = Entries.unparsed(logical.text)
            scene.entries.append(Positioned(line: logical.line, entry: entry, origin: origin))
        }
    }

    private func endParagraph() {
        guard let scene = current, !paragraph.isEmpty else { return }
        let read =
            paragraph.count == 1 && Inline.isEmptyParagraphMarker(paragraph[0])
            ? StyledText() : Inline.read(paragraph)
        paragraph = []
        if scene.section == .notes {
            scene.notes.append(read)
        } else {
            scene.body.append(read)
        }
    }

    // MARK: Scenes

    /// §2.2.
    private func metadata(_ key: String, _ value: ArraySlice<UInt8>, _ line: [UInt8], _ number: Int) {
        guard let scene = current else { return }
        guard ["id", "modified", "tags"].contains(key) else {
            return record(.metadata, line, number, .metadata(.unknownKey))
        }
        guard scene.metadataKeys.insert(key).inserted else {
            return record(.metadata, line, number, .metadata(.repeatedKey))
        }
        switch key {
        case "id":
            let id = Lexical.string(value)
            guard Lexical.isValidID(id.utf8) else {
                return record(.metadata, line, number, .metadata(.badID))
            }
            scene.id = SceneID(rawValue: id)
        case "modified":
            guard let timestamp = Timestamp(Lexical.string(value)) else {
                return record(.metadata, line, number, .metadata(.badDate))
            }
            scene.modified = timestamp
        default:
            scene.tags = Lexical.tags(value)
        }
    }

    /// Reads the finished scene's marks, then its comments, against its body and notes
    /// (§4.7).
    private func endScene() {
        endParagraph()
        endEntry()
        guard let scene = current else { return }
        current = nil
        var body = SceneText(scene.body)
        var notes = SceneText(scene.notes)
        var context = EntryContext(body: body, notes: notes, commentIDs: [])
        let marks = scene.markLines.compactMap { logical -> ParsedMark? in
            switch Entries.mark(logical.text, in: context) {
            case .success(let mark): return mark
            case .failure(let problem): record(.marks, logical.text, logical.line, .mark(problem), in: scene)
            }
            return nil
        }
        var comments: [ParsedComment] = []
        for logical in scene.commentLines {
            switch Entries.comment(logical.text, in: context) {
            case .success(let comment):
                comments.append(comment)
                context.commentIDs.insert(comment.comment.id)
            case .failure(let problem):
                record(.comments, logical.text, logical.line, .comment(problem), in: scene)
            }
        }
        for mark in marks {
            for range in mark.ranges {
                switch (mark.kind, range.part) {
                case (.color(let color), .body): body.setColor(color, in: range.offsets)
                case (.color(let color), .notes): notes.setColor(color, in: range.offsets)
                case (.highlight(let highlight), .body): body.setHighlight(highlight, in: range.offsets)
                case (.highlight(let highlight), .notes): notes.setHighlight(highlight, in: range.offsets)
                }
            }
        }
        for (number, comment) in comments.enumerated() {
            for range in comment.ranges {
                if range.part == .body {
                    body.addComment(number, in: range.offsets)
                } else {
                    notes.addComment(number, in: range.offsets)
                }
            }
        }
        let ids = comments.map(\.comment.id)
        scene.paragraphs = (body.paragraphs(comments: ids), notes.paragraphs(comments: ids))
        scene.comments = comments.map(\.comment)
        scenes.append(scene)
    }

    // MARK: Entries

    private func record(
        _ tag: ErrorTag, _ line: [UInt8], _ number: Int, _ reason: ErrorReason = .line,
        in scene: SceneDraft? = nil
    ) {
        let positioned = Positioned(
            line: number, entry: ErrorEntry(tag, Lexical.string(line)), reason: reason)
        if let scene = scene ?? current {
            scene.entries.append(positioned)
        } else {
            bookEntries.append(positioned)
        }
    }

    private func bookEntry(_ tag: ErrorTag, _ line: [UInt8], _ number: Int, _ reason: ErrorReason) {
        bookEntries.append(
            Positioned(line: number, entry: ErrorEntry(tag, Lexical.string(line)), reason: reason))
    }

    // MARK: The book

    func finish(windows1252ByteCount: Int, opened: Timestamp, ids: inout some SceneIDSource) -> ParsedBook {
        var used = Set(scenes.compactMap(\.id))
        var kept: Set<SceneID> = []
        var story: [BookScene] = []
        var boneyard: [BookScene] = []
        var newInScenes: [ErrorEntry] = []
        var firstReasonInScenes: ErrorReason?
        for draft in scenes {
            var notices: [RepairNotice] = []
            let id: SceneID
            if let own = draft.id, kept.insert(own).inserted {
                id = own
            } else {
                id = Self.fresh(&ids, avoiding: &used)
                notices.append(
                    draft.id.map { .duplicateSceneID($0, given: id) } ?? .missingSceneID(given: id))
            }
            if draft.modified == nil {
                notices.append(.missingModified(setTo: opened))
            }
            notices +=
                RepairNotice.lineBreaks(in: draft.tags, of: .scene) + RepairNotice.characters(draft.changed)
            let entries = Positioned.inFileOrder(draft.entries)
            newInScenes += Positioned.new(entries) + notices.map(\.entry)
            firstReasonInScenes =
                firstReasonInScenes ?? Positioned.firstNewReason(entries) ?? notices.first.map(\.reason)
            let scene = BookScene(
                id: id, modified: draft.modified ?? opened, title: SceneTitle(draft.title), tags: draft.tags,
                body: draft.paragraphs.body, notes: draft.paragraphs.notes, comments: draft.comments,
                errors: entries.map(\.entry) + notices.map(\.entry))
            switch draft.list {
            case .story: story.append(scene)
            case .boneyard: boneyard.append(scene)
            }
        }
        var notices: [RepairNotice] = []
        if windows1252ByteCount > 0 { notices.append(.invalidUTF8(byteCount: windows1252ByteCount)) }
        if title == nil { notices.append(.missingTitle) }
        notices += RepairNotice.format(format) + RepairNotice.characters(bookChanged)
        let entries = Positioned.inFileOrder(bookEntries)
        let book = Book(
            title: title ?? BookFormat.untitled, scenes: story, boneyard: boneyard,
            errors: entries.map(\.entry) + notices.map(\.entry))
        return ParsedBook(
            book: book, declaredFormat: format.map(FormatVersion.init),
            newEntries: Positioned.new(entries) + notices.map(\.entry) + newInScenes,
            firstNewReason: Positioned.firstNewReason(entries) ?? notices.first.map(\.reason)
                ?? firstReasonInScenes)
    }

    /// A fresh id that no scene in the file uses. A source that keeps repeating itself gets
    /// a few tries, then the first free `scene-<n>`.
    private static func fresh(_ ids: inout some SceneIDSource, avoiding used: inout Set<SceneID>) -> SceneID {
        for _ in 0..<8 {
            let candidate = ids.sceneID()
            if Lexical.isValidID(Array(candidate.rawValue.utf8)), used.insert(candidate).inserted {
                return candidate
            }
        }
        var counter = 1
        while !used.insert(SceneID(rawValue: "scene-\(counter)")).inserted {
            counter += 1
        }
        return SceneID(rawValue: "scene-\(counter)")
    }
}
