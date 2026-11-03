import Foundation
import Testing

@testable import SceneItCore

/// Every case of `Tests/Corpus`, as its README says to run it. `CORPUS_REGENERATE=1 swift
/// test --filter CorpusConformance` rewrites each case's results from this implementation
/// instead; review the diff before committing it.
@Suite struct CorpusConformanceTests {
    private static let regenerating = ProcessInfo.processInfo.environment["CORPUS_REGENERATE"] == "1"

    @Test func everyGroupHasCasesAndEveryCaseHasItsFiles() throws {
        for group in Corpus.Group.allCases {
            let names = Corpus.names(group)
            #expect(!names.isEmpty, "no \(group.rawValue) cases")
            for name in names {
                for file in [Corpus.File.input, .expected, .entries] {
                    let path = try Corpus.url(group, name, file).path
                    #expect(
                        FileManager.default.fileExists(atPath: path),
                        "\(group.rawValue)/\(name) has no \(file.rawValue)")
                }
            }
        }
    }

    @Test(arguments: Corpus.names(.book))
    func bookCase(_ name: String) throws {
        let parsed = parse(try Corpus.book(name))
        let result = CorpusResult(parsed)
        try check(result, .book, name)
        #expect(try BookFormat.verifiedSerialization(of: parsed.book) == result.serialized)

        #expect(CorpusResult(parse(result.serialized)) == result.readBack, "expected.md reads back as itself")
    }

    @Test(arguments: Corpus.names(.archiveIndex))
    func archiveIndexCase(_ name: String) throws {
        let parsed = ArchiveIndexFormat.parse(try Corpus.archiveIndex(name), filed: Corpus.filedDay)
        let result = CorpusResult(parsed)
        try check(result, .archiveIndex, name)
        #expect(try ArchiveIndexFormat.verifiedSerialization(of: parsed.index) == result.serialized)

        let reread = ArchiveIndexFormat.parse(result.serialized, filed: Corpus.filedDay)
        #expect(CorpusResult(reread) == result.readBack, "expected.md reads back as itself")
    }

    private func check(_ result: CorpusResult, _ group: Corpus.Group, _ name: String) throws {
        let entries = Data(result.entriesText.utf8)
        if Self.regenerating {
            let directory = Corpus.sourceRoot.appending(path: group.rawValue).appending(path: name)
            try result.serialized.write(to: directory.appending(path: Corpus.File.expected.rawValue))
            try entries.write(to: directory.appending(path: Corpus.File.entries.rawValue))
            return
        }
        let expected = try Corpus.data(group, name, .expected)
        #expect(
            result.serialized == expected,
            "\(group.rawValue)/\(name)/expected.md differs; the serialization is:\n\(String(decoding: result.serialized, as: UTF8.self))"
        )
        let expectedEntries = try Corpus.data(group, name, .entries)
        #expect(
            entries == expectedEntries,
            "\(group.rawValue)/\(name)/entries.txt differs; the entries are:\n\(result.entriesText)")
    }
}
