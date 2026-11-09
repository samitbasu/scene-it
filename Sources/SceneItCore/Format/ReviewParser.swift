import Foundation

/// `ReviewFormat.parse`: review format §3, built from the book format's lexical layer, entries
/// and paragraphs. Every line either takes effect or becomes an error entry of the scene (or the
/// review) it was found in, and a section that can't be keyed to a scene of the copy keeps its
/// lines as review-level entries, so damage stays where it is.
enum ReviewParser {
    static func parse(_ bytes: Data, against copy: ReceivedCopy, freshID: () -> ReviewID) -> ParsedReview {
        let decoded = BookTextDecoder.decode(bytes)
        let admitted = CharacterPolicy.fileText(decoded.text)
        let reader = ReviewReader(
            lines: BookParser.lines(admitted.bytes), changes: admitted.changes, copy: copy)
        reader.read()
        return reader.finish(windows1252ByteCount: decoded.windows1252ByteCount, freshID: freshID)
    }
}

private enum ReviewKey: String, CaseIterable {
    case title, format, copy, id
}

/// What a keyed section's lines are, as they're read (review format §3.4).
private enum SectionPart {
    /// The `key: value` lines directly under the heading.
    case metadata
    /// Before any subsection: each line is an entry.
    case body
    case notes, comments, unparsed
}

/// The preamble's subsections (review format §3.3).
private enum PreamblePart {
    case none, notes, unparsed
}

/// One scene's annotations, gathered from every section keyed to it.
private final class SceneAnnotations {
    var notes: [StyledText] = []
    var commentLines: [LogicalLine] = []
    var entries: [Positioned] = []
    var changed: [CharacterChange] = []
}

private final class ReviewReader {
    private let lines: [[UInt8]]
    private var changes: ChangeCursor
    private let copy: ReceivedCopy
    private let copyScenes: Set<SceneID>

    private var keys: Set<ReviewKey> = []
    private var format: Int?
    private var copyID: ExportID?
    private var reviewID: ReviewID?
    private var entries: [Positioned] = []
    private var changed: [CharacterChange] = []
    private var notes: [StyledText] = []
    private var scenes: [SceneID: SceneAnnotations] = [:]

    private var paragraph: [[UInt8]] = []
    private var entry: LogicalLine?

    init(lines: [[UInt8]], changes: [CharacterChange], copy: ReceivedCopy) {
        self.lines = lines
        self.changes = ChangeCursor(changes)
        self.copy = copy
        copyScenes = Set(copy.book.scenes.map(\.id))
    }

    func read() {
        let frontMatter = Lexical.frontMatter(lines)
        for number in frontMatter.lines {
            self.frontMatter(lines[number], number)
        }
        for number in 0..<frontMatter.end {
            changed += changes.through(line: number)
        }
        let starts = (frontMatter.end..<lines.count).filter {
            if case .heading(2, _) = Lexical.kind(of: lines[$0]) { true } else { false }
        }
        preamble(frontMatter.end..<(starts.first ?? lines.count))
        for (index, start) in starts.enumerated() {
            section(start..<(index + 1 < starts.count ? starts[index + 1] : lines.count))
        }
    }

    // MARK: Front matter (§3.2)

    private func frontMatter(_ line: [UInt8], _ number: Int) {
        guard let (name, value) = Lexical.keyValue(line) else {
            return record(.frontMatter, line, number, .frontMatter(.notAField), in: &entries)
        }
        guard let key = ReviewKey(rawValue: name) else {
            return record(.frontMatter, line, number, .frontMatter(.unknownKey), in: &entries)
        }
        guard keys.insert(key).inserted else {
            return record(.frontMatter, line, number, .frontMatter(.repeatedKey), in: &entries)
        }
        switch key {
        case .title:
            break
        case .format:
            guard let format = Lexical.formatNumber(Lexical.fieldUnescaped(value)) else {
                return record(.frontMatter, line, number, .frontMatter(.badFormat), in: &entries)
            }
            self.format = format
        case .copy, .id:
            let id = Lexical.string(value)
            guard Lexical.isValidID(id.utf8) else {
                return record(.frontMatter, line, number, .frontMatter(.badID), in: &entries)
            }
            if key == .copy { copyID = ExportID(rawValue: id) } else { reviewID = ReviewID(rawValue: id) }
        }
    }

    // MARK: The preamble (§3.3)

    private func preamble(_ range: Range<Int>) {
        var part = PreamblePart.none
        for number in range {
            let line = lines[number]
            changed += changes.through(line: number)
            switch Lexical.kind(of: line) {
            case .blank:
                endPreambleBlock(part)
            case .heading(3, let name) where Lexical.equalsIgnoringCase(name, "notes"):
                endPreambleBlock(part)
                part = .notes
            case .heading(3, let name) where Lexical.equalsIgnoringCase(name, "unparsed"):
                endPreambleBlock(part)
                part = .unparsed
            case .heading:
                endPreambleBlock(part)
                record(.line, line, number, in: &entries)
            case .text:
                switch part {
                case .none: record(.line, line, number, in: &entries)
                case .notes: paragraph.append(line)
                case .unparsed:
                    if Lexical.isEntryStart(line) { endPreambleBlock(part) }
                    if !startOrContinueEntry(line, number) { record(.line, line, number, in: &entries) }
                }
            }
        }
        endPreambleBlock(part)
    }

    private func endPreambleBlock(_ part: PreamblePart) {
        if part == .notes, let read = takeParagraph() { notes.append(read) }
        if let logical = takeEntry() {
            let (entry, origin) = Entries.unparsed(logical.text)
            entries.append(Positioned(line: logical.line, entry: entry, origin: origin))
        }
    }

    // MARK: Scene sections (§3.4)

    private func section(_ range: Range<Int>) {
        guard let id = sectionID(range), copyScenes.contains(id) else {
            return orphan(range)
        }
        let scene = scenes[id] ?? SceneAnnotations()
        scenes[id] = scene
        scene.changed += changes.through(line: range.lowerBound)
        var part = SectionPart.metadata
        var metadataKeys: Set<String> = []
        for number in range.dropFirst() {
            let line = lines[number]
            scene.changed += changes.through(line: number)
            switch Lexical.kind(of: line) {
            case .blank:
                endBlock(part, scene)
                if part == .metadata { part = .body }
            case .heading(3, let name) where Self.subsection(name) != nil:
                endBlock(part, scene)
                part = Self.subsection(name)!
            case .heading:
                endBlock(part, scene)
                if part == .metadata { part = .body }
                record(.line, line, number, in: &scene.entries)
            case .text:
                if part == .metadata {
                    if let (key, _) = Lexical.keyValue(line) {
                        metadata(key, line, number, &metadataKeys, scene)
                        continue
                    }
                    part = .body
                }
                switch part {
                case .metadata, .body:
                    record(.line, line, number, in: &scene.entries)
                case .notes:
                    paragraph.append(line)
                case .comments:
                    if Lexical.isEntryStart(line) { endBlock(part, scene) }
                    if !startOrContinueEntry(line, number) {
                        record(.comments, line, number, .comment(.strayLine), in: &scene.entries)
                    }
                case .unparsed:
                    if Lexical.isEntryStart(line) { endBlock(part, scene) }
                    if !startOrContinueEntry(line, number) { record(.line, line, number, in: &scene.entries) }
                }
            }
        }
        endBlock(part, scene)
    }

    /// The first `id:` directly under the section's heading, if it's a valid id.
    private func sectionID(_ range: Range<Int>) -> SceneID? {
        for number in range.dropFirst() {
            guard let (key, value) = Lexical.keyValue(lines[number]) else { return nil }
            guard key == "id" else { continue }
            let id = Lexical.string(value)
            return Lexical.isValidID(id.utf8) ? SceneID(rawValue: id) : nil
        }
        return nil
    }

    /// The only key is `id`; the first one was the section's.
    private func metadata(
        _ key: String, _ line: [UInt8], _ number: Int, _ seen: inout Set<String>, _ scene: SceneAnnotations
    ) {
        guard key == "id" else {
            return record(.metadata, line, number, .metadata(.unknownKey), in: &scene.entries)
        }
        if !seen.insert(key).inserted {
            record(.metadata, line, number, .metadata(.repeatedKey), in: &scene.entries)
        }
    }

    /// A section that can't be anchored to anything: every non-blank line of it is kept as a
    /// review-level `[line]` entry, then a notice says why.
    private func orphan(_ range: Range<Int>) {
        var last = range.lowerBound
        for number in range {
            changed += changes.through(line: number)
            guard !lines[number].isEmpty else { continue }
            record(.line, lines[number], number, in: &entries)
            last = number
        }
        let notice: ReviewNotice = sectionID(range).map { .sectionForNoScene($0) } ?? .sectionWithoutID
        entries.append(Positioned(line: last, entry: notice.entry, reason: .notice))
    }

    private static func subsection(_ name: ArraySlice<UInt8>) -> SectionPart? {
        let names: [(String, SectionPart)] = [
            ("notes", .notes), ("comments", .comments), ("unparsed", .unparsed),
        ]
        return names.first { Lexical.equalsIgnoringCase(name, $0.0) }?.1
    }

    private func endBlock(_ part: SectionPart, _ scene: SceneAnnotations) {
        if part == .notes, let read = takeParagraph() { scene.notes.append(read) }
        guard let logical = takeEntry() else { return }
        switch part {
        case .comments:
            scene.commentLines.append(logical)
        default:
            let (entry, origin) = Entries.unparsed(logical.text)
            scene.entries.append(Positioned(line: logical.line, entry: entry, origin: origin))
        }
    }

    // MARK: Lines

    /// Book format §4.1: an entry starts with `- `; a line right under an entry continues it.
    /// `false` for a stray line, which the caller records. The caller ends the entry before.
    private func startOrContinueEntry(_ line: [UInt8], _ number: Int) -> Bool {
        if Lexical.isEntryStart(line) {
            entry = LogicalLine(line: number, text: line)
            return true
        }
        guard entry != nil else { return false }
        entry?.text += [Lexical.space] + line
        return true
    }

    private func takeEntry() -> LogicalLine? {
        defer { entry = nil }
        return entry
    }

    private func takeParagraph() -> StyledText? {
        guard !paragraph.isEmpty else { return nil }
        defer { paragraph = [] }
        return paragraph.count == 1 && Inline.isEmptyParagraphMarker(paragraph[0])
            ? StyledText() : Inline.read(paragraph)
    }

    private func record(
        _ tag: ErrorTag, _ line: [UInt8], _ number: Int, _ reason: ErrorReason = .line,
        in list: inout [Positioned]
    ) {
        list.append(Positioned(line: number, entry: ErrorEntry(tag, Lexical.string(line)), reason: reason))
    }

    // MARK: The review

    func finish(windows1252ByteCount: Int, freshID: () -> ReviewID) -> ParsedReview {
        var newInScenes: [ErrorEntry] = []
        var book = Book(title: copy.book.title)
        for copyScene in copy.book.scenes {
            guard let annotations = scenes[copyScene.id] else {
                book.scenes.append(copyScene)
                continue
            }
            let (scene, new) = annotated(copyScene, with: annotations)
            book.scenes.append(scene)
            newInScenes += new
        }
        let id = reviewID ?? freshID()
        var notices: [ErrorEntry] = []
        if windows1252ByteCount > 0 {
            notices.append(RepairNotice.invalidUTF8(byteCount: windows1252ByteCount).entry)
        }
        notices += ReviewNotice.format(format).map(\.entry)
        if copyID == nil { notices.append(ReviewNotice.missingCopy(copy.export).entry) }
        if reviewID == nil { notices.append(ReviewNotice.missingID(given: id).entry) }
        notices += RepairNotice.characters(changed).map(\.entry)
        let ordered = Positioned.inFileOrder(entries)
        book.errors = ordered.map(\.entry) + notices
        let review = Review(
            book: book, notes: SceneText(notes).paragraphs(comments: []), copy: copyID ?? copy.export, id: id)
        return ParsedReview(
            review: review, declaredFormat: format.map(FormatVersion.init),
            newEntries: Positioned.new(ordered) + notices + newInScenes)
    }

    /// The copy's scene with the reviewer's comments on its text, checked against it (§3.5),
    /// and the reviewer's notes; and the entries the parse made for it.
    private func annotated(_ scene: BookScene, with annotations: SceneAnnotations) -> (
        BookScene, [ErrorEntry]
    ) {
        var body = SceneText(scene.body.map(StyledText.init))
        var context = EntryContext(body: body, notes: SceneText([]), commentIDs: [])
        var comments: [ParsedComment] = []
        for logical in annotations.commentLines {
            switch Entries.comment(logical.text, in: context) {
            case .success(let comment):
                comments.append(comment)
                context.commentIDs.insert(comment.comment.id)
            case .failure(let problem):
                record(.comments, logical.text, logical.line, .comment(problem), in: &annotations.entries)
            }
        }
        for (number, comment) in comments.enumerated() {
            for range in comment.ranges { body.addComment(number, in: range.offsets) }
        }
        let entries = Positioned.inFileOrder(annotations.entries)
        let notices = RepairNotice.characters(annotations.changed).map(\.entry)
        var annotated = scene
        annotated.body = body.paragraphs(comments: comments.map(\.comment.id))
        annotated.notes = SceneText(annotations.notes).paragraphs(comments: [])
        annotated.comments = comments.map(\.comment)
        annotated.errors = entries.map(\.entry) + notices
        return (annotated, Positioned.new(entries) + notices)
    }
}

extension StyledText {
    /// A paragraph's text and styles, as the parser would have read them.
    init(_ paragraph: Paragraph) {
        self.init()
        for run in paragraph.runs {
            let bytes = Array(run.text.utf8)
            text += bytes
            styles += repeatElement(StyleBits(run.styles), count: bytes.count)
        }
    }
}
