import Foundation
import Testing

@testable import SceneItCore

/// The format's test vectors as plain files, in `Tests/Corpus` (its README defines the
/// layout): any implementation of the format can be checked against them.
enum Corpus {
    enum Group: String, CaseIterable, Sendable {
        case book
        case archiveIndex = "archive-index"
    }

    enum File: String {
        case input = "input.md"
        case expected = "expected.md"
        case entries = "entries.txt"
    }

    static let root = Bundle.module.url(forResource: "Corpus", withExtension: nil)

    /// Where the corpus is in the source tree, for writing regenerated results.
    static let sourceRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Corpus")

    /// The names of `group`'s cases, sorted; empty if the corpus is missing, which
    /// `CorpusConformanceTests` reports.
    static func names(_ group: Group) -> [String] {
        guard let root,
            let names = try? FileManager.default.contentsOfDirectory(
                atPath: root.appending(path: group.rawValue).path)
        else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    static func url(_ group: Group, _ name: String, _ file: File) throws -> URL {
        try #require(root, "the corpus isn't in the test bundle").appending(path: group.rawValue).appending(
            path: name
        ).appending(path: file.rawValue)
    }

    static func data(_ group: Group, _ name: String, _ file: File) throws -> Data {
        try Data(contentsOf: url(group, name, file))
    }

    /// The bytes of a book case's `input.md`.
    static func book(_ name: String) throws -> Data {
        try data(.book, name, .input)
    }

    static func archiveIndex(_ name: String) throws -> Data {
        try data(.archiveIndex, name, .input)
    }

    /// The day a filed copy with no valid `filed` line gets: one per copy, so a case can
    /// tell which copy's default it is.
    static func filedDay(_ number: FiledCopyNumber) -> CalendarDay {
        CalendarDay(year: 2026, month: 3, day: 1 + number.value % 28)!
    }
}

/// The parse of a book case's `input.md`.
func parse(case name: String) throws -> ParsedBook {
    parse(try Corpus.book(name))
}

/// The only scene of a book case, which must have exactly one.
func onlyScene(case name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> BookScene {
    let book = try parse(case: name).book
    try #require(book.scenes.count == 1 && book.boneyard.isEmpty, sourceLocation: sourceLocation)
    return book.scenes[0]
}

/// A dictionary of `Tests/Corpus/fuzz-seeds`, in libFuzzer's format: one `"token"` per line,
/// with `\\`, `\"` and `\xHH` escapes.
enum FuzzDictionary {
    static func tokens(_ name: String) throws -> [[UInt8]] {
        let url = try #require(Corpus.root).appending(path: "fuzz-seeds").appending(path: "\(name).dict")
        let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n")
        return try lines.filter { !$0.hasPrefix("#") }.map { line in
            try #require(line.count >= 2 && line.first == "\"" && line.last == "\"", "\(name): \(line)")
            return try unescaped(Array(line.utf8.dropFirst().dropLast()))
        }
    }

    static func strings(_ name: String) throws -> [String] {
        try tokens(name).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func unescaped(_ escaped: [UInt8]) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var index = 0
        while index < escaped.count {
            guard escaped[index] == UInt8(ascii: "\\") else {
                bytes.append(escaped[index])
                index += 1
                continue
            }
            let next = try #require(escaped.indices.contains(index + 1) ? escaped[index + 1] : nil)
            if next == UInt8(ascii: "x") {
                let hex = try #require(
                    escaped.indices.contains(index + 3) ? escaped[(index + 2)...(index + 3)] : nil)
                bytes.append(try #require(UInt8(String(decoding: hex, as: UTF8.self), radix: 16)))
                index += 4
            } else {
                bytes.append(next)
                index += 2
            }
        }
        return bytes
    }
}

/// What a parse produced, in the corpus's terms: the canonical bytes, and the error entries
/// in the Errors tab's order.
struct CorpusResult: Equatable {
    var serialized: Data
    var entries: [CorpusEntry]

    init(_ parsed: ParsedBook) {
        let book = parsed.book
        let refs = book.errorGroups.flatMap(\.refs)
        serialized = BookFormat.serialize(book)
        entries = zip(refs, CorpusEntry.origins(of: refs.map(\.entry), new: parsed.newEntries)).map {
            CorpusEntry(origin: $1, reason: BookFormat.reason(for: $0, in: book).corpusCode, entry: $0.entry)
        }
    }

    init(_ parsed: ParsedArchiveIndex) {
        let all = Array(parsed.index.errorEntries.joined())
        serialized = ArchiveIndexFormat.serialize(parsed.index)
        entries = zip(all, CorpusEntry.origins(of: all, new: parsed.newEntries)).map {
            CorpusEntry(origin: $1, reason: CorpusEntry.noReason, entry: $0)
        }
    }

    /// What parsing `serialized` must give: the same bytes, and the same entries, now all
    /// read from `### Unparsed` sections.
    var readBack: CorpusResult {
        var result = self
        for index in result.entries.indices { result.entries[index].origin = .preserved }
        return result
    }

    /// `entries.txt`'s contents.
    var entriesText: String {
        entries.map { "\($0)\n" }.joined()
    }
}

/// One line of `entries.txt`: `<origin> <reason> - [<tag>] <payload>`.
struct CorpusEntry: Equatable, CustomStringConvertible {
    enum Origin: String {
        /// This parse made it.
        case new
        /// Read from an `### Unparsed` section as it was.
        case preserved
    }

    /// The archive index has no Errors tab, so its entries have no reason (book format §10 Q12).
    static let noReason = "n/a"

    var origin: Origin
    var reason: String
    var entry: ErrorEntry

    var description: String {
        "\(origin.rawValue) \(reason) - \(entry)"
    }

    /// Which of `entries` are among `new`, which lists them in the same order.
    static func origins(of entries: [ErrorEntry], new: [ErrorEntry]) -> [Origin] {
        var remaining = new[...]
        let origins = entries.map { entry in
            guard remaining.first == entry else { return Origin.preserved }
            remaining.removeFirst()
            return .new
        }
        #expect(remaining.isEmpty, "new entries out of order: \(remaining)")
        return origins
    }
}

extension ErrorReason {
    /// The reason's code in `entries.txt` (Tests/Corpus/README.md).
    var corpusCode: String {
        switch self {
        case .comment(let problem), .mark(let problem): problem.rawValue
        case .metadata(let problem), .frontMatter(let problem): problem.corpusCode
        case .line: "line"
        case .notice: "notice"
        case .readsNow: "reads-now"
        }
    }
}

extension FieldProblem {
    var corpusCode: String {
        switch self {
        case .notAField: "not-a-field"
        case .unknownKey: "unknown-key"
        case .repeatedKey: "repeated-key"
        case .badID: "bad-id"
        case .idInUse: "id-in-use"
        case .badDate: "bad-date"
        case .badFormat: "bad-format"
        case .otherFormat: "other-format"
        }
    }
}
