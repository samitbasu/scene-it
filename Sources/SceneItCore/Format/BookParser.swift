import Foundation

/// `BookFormat.parse`: a single pass over the file's trimmed lines, with no way to fail.
/// Every line either takes effect or becomes an error entry of the scene (or the book) it
/// was found in, so damage stays where it is.
enum BookParser {
    static func parse(_ bytes: Data, opened: Timestamp, ids: inout some SceneIDSource) -> ParsedBook {
        let decoded = BookTextDecoder.decode(bytes)
        let admitted = CharacterPolicy.admitLatin1(decoded.text)
        let reader = Reader(lines: lines(admitted.bytes), replacements: admitted.replacements)
        reader.read()
        return reader.finish(windows1252ByteCount: decoded.windows1252ByteCount, opened: opened, ids: &ids)
    }

    /// §1.2 step 8 and §1.3: the text's physical lines, trimmed. A final `\n` ends the last
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

/// An entry (or a stray line) and the line it started on, so entries found at different
/// times can be put in file order.
private struct LogicalLine {
    let line: Int
    var text: [UInt8]
}

private enum SceneList {
    case story, boneyard
}

private struct Positioned {
    let line: Int
    let entry: ErrorEntry
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
    var replaced: [Unicode.Scalar] = []
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
    private let replacements: [Replacement]
    private var nextReplacement = 0

    private var bookEntries: [Positioned] = []
    private var bookReplaced: [Unicode.Scalar] = []
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

    init(lines: [[UInt8]], replacements: [Replacement]) {
        self.lines = lines
        self.replacements = replacements
    }

    func read() {
        var index = 0
        if let first = lines.firstIndex(where: { !$0.isEmpty }), lines[first] == Self.frontMatterFence {
            index = first + 1
            while index < lines.count {
                let line = lines[index]
                if line == Self.frontMatterFence {
                    index += 1
                    break
                }
                if case .heading = Lexical.kind(of: line) { break }
                if !line.isEmpty { frontMatter(line, index) }
                index += 1
            }
        }
        for number in 0..<index {
            bookReplaced += replaced(on: number)
        }
        while index < lines.count {
            process(index)
            index += 1
        }
        endScene()
    }

    private static let frontMatterFence = Array("---".utf8)

    // MARK: Front matter (§1.5)

    private func frontMatter(_ line: [UInt8], _ number: Int) {
        guard let (key, value) = Lexical.keyValue(line), ["title", "format"].contains(key),
            frontMatterKeys.insert(key).inserted
        else {
            return bookEntry(.frontMatter, line, number)
        }
        let unescaped = Lexical.fieldUnescaped(value)
        if key == "title" {
            title = Lexical.string(unescaped)
        } else if let number = decimal(unescaped) {
            format = number
        } else {
            bookEntry(.frontMatter, line, number)
        }
    }

    private func decimal(_ digits: [UInt8]) -> Int? {
        guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
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
            current.replaced += replaced(on: number)
        } else {
            bookReplaced += replaced(on: number)
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
            case .comments?: record(.comments, line, number)
            case .marks?: record(.marks, line, number)
            default: record(.line, line, number)
            }
        }
    }

    private func endEntry() {
        guard let logical = entry else { return }
        entry = nil
        guard let scene = current else {
            bookEntries.append(Positioned(line: logical.line, entry: Entries.unparsed(logical.text)))
            return
        }
        switch scene.section {
        case .comments: scene.commentLines.append(logical)
        case .marks: scene.markLines.append(logical)
        default: scene.entries.append(Positioned(line: logical.line, entry: Entries.unparsed(logical.text)))
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
        guard let scene = current, ["id", "modified", "tags"].contains(key),
            scene.metadataKeys.insert(key).inserted
        else {
            return record(.metadata, line, number)
        }
        switch key {
        case "id":
            guard Lexical.isValidID(value) else { return record(.metadata, line, number) }
            scene.id = SceneID(rawValue: Lexical.string(value))
        case "modified":
            guard let timestamp = Timestamp(Lexical.string(value)) else {
                return record(.metadata, line, number)
            }
            scene.modified = timestamp
        default:
            scene.tags = Self.tags(value)
        }
    }

    static func tags(_ value: ArraySlice<UInt8>) -> [String] {
        var pieces: [ArraySlice<UInt8>] = []
        var start = value.startIndex
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == Lexical.backslash {
                index += 2
                continue
            }
            if value[index] == Lexical.comma {
                pieces.append(value[start..<index])
                start = index + 1
            }
            index += 1
        }
        pieces.append(value[min(start, value.endIndex)...])
        return pieces.compactMap { piece in
            var tag = Lexical.trim(piece)[...]
            if tag.first == Lexical.hash { tag = tag.dropFirst() }
            let unescaped = Lexical.fieldUnescaped(tag)
            return unescaped.isEmpty ? nil : Lexical.string(unescaped)
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
        let marks = scene.markLines.compactMap { logical -> ParsedMark? in
            switch Entries.mark(logical.text, in: EntryContext(body: body, notes: notes, commentIDs: [])) {
            case .success(let mark): return mark
            case .failure: record(.marks, logical.text, logical.line, in: scene)
            }
            return nil
        }
        var comments: [ParsedComment] = []
        for logical in scene.commentLines {
            let context = EntryContext(body: body, notes: notes, commentIDs: Set(comments.map(\.comment.id)))
            switch Entries.comment(logical.text, in: context) {
            case .success(let comment): comments.append(comment)
            case .failure: record(.comments, logical.text, logical.line, in: scene)
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

    private func record(_ tag: ErrorTag, _ line: [UInt8], _ number: Int, in scene: SceneDraft? = nil) {
        let positioned = Positioned(line: number, entry: ErrorEntry(tag, Lexical.string(line)))
        if let scene = scene ?? current {
            scene.entries.append(positioned)
        } else {
            bookEntries.append(positioned)
        }
    }

    private func bookEntry(_ tag: ErrorTag, _ line: [UInt8], _ number: Int) {
        bookEntries.append(Positioned(line: number, entry: ErrorEntry(tag, Lexical.string(line))))
    }

    private func replaced(on line: Int) -> [Unicode.Scalar] {
        var found: [Unicode.Scalar] = []
        while nextReplacement < replacements.count, replacements[nextReplacement].line <= line {
            found.append(replacements[nextReplacement].scalar)
            nextReplacement += 1
        }
        return found
    }

    // MARK: The book

    func finish(windows1252ByteCount: Int, opened: Timestamp, ids: inout some SceneIDSource) -> ParsedBook {
        var used = Set(scenes.compactMap(\.id))
        var kept: Set<SceneID> = []
        var story: [BookScene] = []
        var boneyard: [BookScene] = []
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
            notices += replacedNotice(draft.replaced)
            let scene = BookScene(
                id: id, modified: draft.modified ?? opened, title: SceneTitle(draft.title), tags: draft.tags,
                body: draft.paragraphs.body, notes: draft.paragraphs.notes, comments: draft.comments,
                errors: Self.inFileOrder(draft.entries) + notices.map(\.entry))
            switch draft.list {
            case .story: story.append(scene)
            case .boneyard: boneyard.append(scene)
            }
        }
        var notices: [RepairNotice] = []
        if windows1252ByteCount > 0 { notices.append(.invalidUTF8(byteCount: windows1252ByteCount)) }
        if title == nil { notices.append(.missingTitle) }
        if let format, format != FormatVersion.current.number {
            notices.append(.otherFormat(format))
        } else if format == nil {
            notices.append(.missingFormat)
        }
        notices += replacedNotice(bookReplaced)
        let book = Book(
            title: title ?? BookFormat.untitled, scenes: story, boneyard: boneyard,
            errors: Self.inFileOrder(bookEntries) + notices.map(\.entry))
        return ParsedBook(book: book, declaredFormat: format.map(FormatVersion.init))
    }

    private func replacedNotice(_ scalars: [Unicode.Scalar]) -> [RepairNotice] {
        scalars.isEmpty ? [] : [.replacedCharacters(CharacterPolicy.distinct(scalars))]
    }

    private static func inFileOrder(_ entries: [Positioned]) -> [ErrorEntry] {
        entries.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(
            \.element.entry)
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
