import Foundation

/// `Archive/index.md`, the File Cabinet's index (book format §8), on the book format's
/// machinery: front matter, `##` sections, `key: value` lines, tags, field escapes and
/// `### Unparsed`. Like `BookFormat`, `parse` never fails and `serialize` is canonical.
///
/// Reconciling the index with the filed copies on disk (a copy with no section, a section
/// with no copy, missing counts) belongs to the archive, which has the files.
public enum ArchiveIndexFormat {
    /// Reads any bytes as an index. `filed` gives the date for a section with no `filed`
    /// line, or a bad one: the archive gives the filed copy's modification day.
    public static func parse(_ bytes: Data, filed: (FiledCopyNumber) -> CalendarDay) -> ParsedArchiveIndex {
        let decoded = BookTextDecoder.decode(bytes)
        let admitted = CharacterPolicy.admitLatin1(decoded.text)
        let reader = IndexReader(lines: BookParser.lines(admitted.bytes), replacements: admitted.replacements)
        reader.read()
        return reader.finish(windows1252ByteCount: decoded.windows1252ByteCount, filed: filed)
    }

    public static func serialize(_ index: ArchiveIndex) -> Data {
        var blocks = ["---\nformat: \(FormatVersion.current)\n---"]
        blocks += BookSerializer.unparsed(index.errors)
        for copy in index.copies.sorted(by: { $0.number < $1.number }) {
            blocks.append(sectionLines(copy).joined(separator: "\n"))
            blocks += BookSerializer.unparsed(copy.errors)
        }
        return Data((blocks.joined(separator: "\n\n") + "\n").utf8)
    }

    /// A copy's heading and metadata lines, as `serialize` writes them.
    static func sectionLines(_ copy: FiledCopy) -> [String] {
        var lines = ["## \(copy.number.fileName)", "filed: \(copy.filed)"]
        if !copy.tags.isEmpty { lines.append(BookSerializer.tagsLine(copy.tags)) }
        if !copy.note.isEmpty { lines.append("note: " + FieldEscaping.freeText.escape(copy.note)) }
        if let counts = copy.counts {
            lines += ["scenes: \(counts.scenes)", "words: \(counts.words)", "comments: \(counts.comments)"]
        }
        return lines
    }

    /// The bytes to save for `index`, after checking that they read back as `index` itself,
    /// with no new error entries, and serialize again to the same bytes (book format §7.2).
    /// `index.copies` must be in ascending order, as a parse leaves them.
    public static func verifiedSerialization(of index: ArchiveIndex) throws(VerificationFailure) -> Data {
        let bytes = serialize(index)
        let reread = parse(bytes, filed: { _ in verificationDay }).index
        guard reread.errorEntries == index.errorEntries else {
            let had = Set(index.errorEntries.joined())
            throw .newEntries(reread.errorEntries.joined().filter { !had.contains($0) })
        }
        guard reread == index else { throw .changed }
        guard serialize(reread) == bytes else { throw .unstable }
        return bytes
    }

    private static let verificationDay = CalendarDay(Date(timeIntervalSince1970: 0), in: .gmt)
}

/// What `ArchiveIndexFormat.parse` read.
public struct ParsedArchiveIndex: Hashable, Sendable {
    public var index: ArchiveIndex
    /// The error entries this parse made, as `ParsedBook.newEntries`: entries the file
    /// already held in `### Unparsed` sections aren't among them.
    public var newEntries: [ErrorEntry]
    /// The index's `format:` value, as `ParsedBook.declaredFormat`.
    public var declaredFormat: FormatVersion?

    /// Whether a newer Scene It wrote the index: rewriting it here could lose what that
    /// version added, so it should be left as it is.
    public var isNewerThanSupported: Bool {
        declaredFormat?.isNewerThanSupported ?? false
    }
}

private final class SectionDraft {
    let number: FiledCopyNumber
    var keys: Set<String> = []
    var filed: CalendarDay?
    var tags: [String] = []
    var note = ""
    /// Only the valid ones.
    var counts: [String: Int] = [:]
    var entries: [Positioned] = []
    var replaced: [Unicode.Scalar] = []
    var inUnparsed = false

    init(number: FiledCopyNumber) {
        self.number = number
    }

    func finish(filed defaultDay: (FiledCopyNumber) -> CalendarDay) -> (FiledCopy, new: [ErrorEntry]) {
        let day = filed ?? defaultDay(number)
        let notices =
            (keys.contains("filed") ? [] : [RepairNotice.missingFiledDate(setTo: day)])
            + RepairNotice.replaced(replaced)
        let ordered = Positioned.inFileOrder(entries)
        var cached: FiledCopyCounts?
        if let scenes = counts["scenes"], let words = counts["words"], let comments = counts["comments"] {
            cached = FiledCopyCounts(scenes: scenes, words: words, comments: comments)
        }
        let copy = FiledCopy(
            number: number, filed: day, tags: tags, note: note, counts: cached,
            errors: ordered.map(\.entry) + notices.map(\.entry))
        return (copy, Positioned.new(ordered) + notices.map(\.entry))
    }
}

private final class IndexReader {
    private enum Place {
        /// After the front matter, before any section.
        case preamble
        /// In the index's own `### Unparsed`.
        case unparsed
        case section(SectionDraft)
        /// Under a `##` heading that isn't a filed copy's, or repeats one: each line is the
        /// index's `[line]` entry.
        case ignored
    }

    private static let keys: Set = ["filed", "tags", "note", "scenes", "words", "comments"]

    private let lines: [[UInt8]]
    private var replacements: ReplacementCursor
    private var entries: [Positioned] = []
    private var replaced: [Unicode.Scalar] = []
    private var frontMatterKeys: Set<String> = []
    private var format: Int?
    private var place = Place.preamble
    private var sections: [SectionDraft] = []
    private var entry: LogicalLine?

    init(lines: [[UInt8]], replacements: [Replacement]) {
        self.lines = lines
        self.replacements = ReplacementCursor(replacements)
    }

    func read() {
        let frontMatter = Lexical.frontMatter(lines)
        for number in frontMatter.lines {
            self.frontMatter(lines[number], number)
        }
        for number in 0..<frontMatter.end {
            replaced += replacements.through(line: number)
        }
        for number in frontMatter.end..<lines.count {
            process(number)
        }
        endEntry()
    }

    /// §8: `format` is the only key.
    private func frontMatter(_ line: [UInt8], _ number: Int) {
        guard let (key, value) = Lexical.keyValue(line), key == "format",
            frontMatterKeys.insert(key).inserted,
            let format = Lexical.formatNumber(Lexical.fieldUnescaped(value))
        else {
            return entries.append(
                Positioned(line: number, entry: ErrorEntry(.frontMatter, Lexical.string(line))))
        }
        self.format = format
    }

    private func process(_ number: Int) {
        let line = lines[number]
        let kind = Lexical.kind(of: line)
        if case .heading(2, let name) = kind {
            endEntry()
            startSection(named: name)
        }
        if case .section(let section) = place {
            section.replaced += replacements.through(line: number)
        } else {
            replaced += replacements.through(line: number)
        }
        switch kind {
        case .heading(2, _):
            if case .ignored = place { record(.line, line, number) }
        case .blank:
            endEntry()
        case .heading(3, let name) where Lexical.equalsIgnoringCase(name, "unparsed"):
            endEntry()
            switch place {
            case .preamble, .unparsed: place = .unparsed
            case .section(let section): section.inUnparsed = true
            case .ignored: record(.line, line, number)
            }
        case .heading:
            endEntry()
            record(.line, line, number)
        case .text:
            text(line, number)
        }
    }

    /// The first section for each filed copy wins.
    private func startSection(named name: ArraySlice<UInt8>) {
        guard let copy = FiledCopyNumber(fileName: Lexical.string(name)),
            !sections.contains(where: { $0.number == copy })
        else {
            place = .ignored
            return
        }
        let section = SectionDraft(number: copy)
        sections.append(section)
        place = .section(section)
    }

    private func text(_ line: [UInt8], _ number: Int) {
        switch place {
        case .section(let section) where !section.inUnparsed:
            guard let (key, value) = Lexical.keyValue(line) else { return record(.line, line, number) }
            metadata(section, key, value, line, number)
        case .section, .unparsed:
            if Lexical.isEntryStart(line) {
                endEntry()
                entry = LogicalLine(line: number, text: line)
            } else if entry != nil {
                entry?.text += [Lexical.space] + line
            } else {
                record(.line, line, number)
            }
        case .preamble, .ignored:
            record(.line, line, number)
        }
    }

    /// A bad `filed` is an entry; bad counts are silently recomputed (§8).
    private func metadata(
        _ section: SectionDraft, _ key: String, _ value: ArraySlice<UInt8>, _ line: [UInt8], _ number: Int
    ) {
        guard Self.keys.contains(key), section.keys.insert(key).inserted else {
            return record(.metadata, line, number)
        }
        switch key {
        case "filed":
            guard let day = CalendarDay(Lexical.string(value)) else { return record(.metadata, line, number) }
            section.filed = day
        case "tags":
            section.tags = Lexical.tags(value)
        case "note":
            section.note = Lexical.string(Lexical.fieldUnescaped(value))
        default:
            section.counts[key] = Lexical.decimal(value)
        }
    }

    private func endEntry() {
        guard let logical = entry else { return }
        entry = nil
        let (read, origin) = Entries.unparsed(logical.text)
        add(Positioned(line: logical.line, entry: read, origin: origin))
    }

    private func record(_ tag: ErrorTag, _ line: [UInt8], _ number: Int) {
        add(Positioned(line: number, entry: ErrorEntry(tag, Lexical.string(line))))
    }

    /// To the current section, or else the index.
    private func add(_ entry: Positioned) {
        if case .section(let section) = place {
            section.entries.append(entry)
        } else {
            entries.append(entry)
        }
    }

    func finish(windows1252ByteCount: Int, filed: (FiledCopyNumber) -> CalendarDay) -> ParsedArchiveIndex {
        var copies: [FiledCopy] = []
        var newInSections: [ErrorEntry] = []
        for section in sections {
            let (copy, new) = section.finish(filed: filed)
            copies.append(copy)
            newInSections += new
        }
        var notices: [RepairNotice] = []
        if windows1252ByteCount > 0 { notices.append(.invalidUTF8(byteCount: windows1252ByteCount)) }
        notices += RepairNotice.format(format) + RepairNotice.replaced(replaced)
        let ordered = Positioned.inFileOrder(entries)
        let index = ArchiveIndex(
            copies: copies.sorted { $0.number < $1.number },
            errors: ordered.map(\.entry) + notices.map(\.entry))
        return ParsedArchiveIndex(
            index: index, newEntries: Positioned.new(ordered) + notices.map(\.entry) + newInSections,
            declaredFormat: format.map(FormatVersion.init))
    }
}
