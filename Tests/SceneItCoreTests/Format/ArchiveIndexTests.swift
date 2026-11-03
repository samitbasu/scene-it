import Foundation
import Testing

@testable import SceneItCore

private func parseIndex(_ data: Data) -> ParsedArchiveIndex {
    ArchiveIndexFormat.parse(data, filed: Corpus.filedDay)
}

private func parseIndex(_ text: String) -> ParsedArchiveIndex {
    parseIndex(Data(text.utf8))
}

private func serialized(_ index: ArchiveIndex) -> String {
    String(decoding: ArchiveIndexFormat.serialize(index), as: UTF8.self)
}

private func copy(_ number: Int) -> FiledCopyNumber {
    FiledCopyNumber(number)!
}

private func day(_ text: String) throws -> CalendarDay {
    try #require(CalendarDay(text))
}

/// Book format §8. Each of its rules with an input and a result is a corpus case
/// (Tests/Corpus/archive-index), which pins its bytes and entries.
@Suite struct ArchiveIndexTests {
    @Test func theSpecExampleReadsAsWrittenAndIsCanonical() throws {
        let example = try Corpus.archiveIndex("s8-example")
        #expect(example == (try Corpus.data(.archiveIndex, "s8-example", .expected)))
        let parsed = parseIndex(example)
        #expect(
            parsed.index
                == ArchiveIndex(copies: [
                    FiledCopy(
                        number: copy(1), filed: try day("2026-09-14"), tags: ["first draft"],
                        counts: FiledCopyCounts(scenes: 22, words: 48210, comments: 31)),
                    FiledCopy(
                        number: copy(2), filed: try day("2026-10-31"),
                        tags: ["draft 4", "before the ending"],
                        note: "Before the ending rewrite",
                        counts: FiledCopyCounts(scenes: 24, words: 51336, comments: 44)),
                ]))
    }

    @Test func anEmptyIndexIsJustTheFrontMatterAndItIsWhatANewPackageHolds() {
        #expect(serialized(ArchiveIndex()) == "---\nformat: 2\n---\n")
        #expect(BookPackage.emptyArchiveIndex == ArchiveIndexFormat.serialize(ArchiveIndex()))
        let parsed = parseIndex(BookPackage.emptyArchiveIndex)
        #expect(parsed.index == ArchiveIndex() && parsed.newEntries.isEmpty)
    }

    // MARK: Writing

    @Test func notesAndTagsUseTheFieldEscapes() {
        let index = ArchiveIndex(copies: [
            FiledCopy(
                number: copy(3), filed: CalendarDay(year: 2026, month: 1, day: 1)!,
                tags: ["a, b", "#c", " d "],
                note: " Two\nlines \\ and | bars ")
        ])
        let text = serialized(index)
        #expect(text.contains("tags: a\\, b, \\#c, \\ d\\ \n"))
        #expect(text.contains("note: \\ Two\\nlines \\\\ and | bars\\ \n"))
        #expect(parseIndex(text).index == index)
    }

    // MARK: Names and dates

    @Test func filedCopyNamesHaveAtLeastFourDigitsAndOneSpellingEach() {
        #expect(copy(1).fileName == "save0001.md")
        #expect(copy(12345).fileName == "save12345.md")
        #expect(FiledCopyNumber(fileName: "save0001.md") == copy(1))
        #expect(FiledCopyNumber(fileName: "save12345.md") == copy(12345))
        for name in [
            "save01.md", "save00001.md", "save0001.json", "save+001.md", "save 001.md", "save.md",
            "save０００1.md",
        ] {
            #expect(FiledCopyNumber(fileName: name) == nil, "\(name)")
        }
        #expect(FiledCopyNumber(-1) == nil)
        let layout = PackageLayout(root: URL(filePath: "/Books/Novel.sceneit"))
        #expect(
            layout.filedCopy(copy(7)).path(percentEncoded: false)
                == "/Books/Novel.sceneit/Archive/save0007.md")
    }

    @Test func calendarDaysAreExactlyYearMonthDay() throws {
        #expect(try day("2028-02-29").description == "2028-02-29")
        #expect(CalendarDay("2027-02-29") == nil)
        #expect(CalendarDay(year: 10000, month: 1, day: 1) == nil)
        #expect(try day("0000-01-01") < day("2026-01-01"))
        let late = try timestamp("2026-11-03T00:20:00Z").date
        #expect(CalendarDay(late, in: .gmt).description == "2026-11-03")
        #expect(CalendarDay(late, in: TimeZone(secondsFromGMT: -3600)!).description == "2026-11-02")
    }

    // MARK: Properties

    @Test func generatedIndexesRoundTripWithNoNewEntries() throws {
        for seed in UInt64(0)..<300 {
            var generator = BookGenerator(seed: seed ^ fuzzSalt)
            let index = generator.index()
            let bytes = try ArchiveIndexFormat.verifiedSerialization(of: index)
            let parsed = parseIndex(bytes)
            #expect(parsed.newEntries.isEmpty, "seed \(seed)")
            #expect(parsed.index == index, "seed \(seed)")
            #expect(ArchiveIndexFormat.serialize(parsed.index) == bytes, "seed \(seed)")
        }
    }

    @Test func theGeneratorCoversEveryField() {
        var sawCounts = false
        var sawNoCounts = false
        var sawNote = false
        var sawTags = false
        var sawErrors = false
        for seed in UInt64(0)..<300 {
            var generator = BookGenerator(seed: seed ^ fuzzSalt)
            let index = generator.index()
            sawErrors = sawErrors || !index.errorEntries.joined().isEmpty
            for copy in index.copies {
                sawCounts = sawCounts || copy.counts != nil
                sawNoCounts = sawNoCounts || copy.counts == nil
                sawNote = sawNote || copy.note.contains("\n")
                sawTags = sawTags || copy.tags.count > 1
            }
        }
        #expect(sawCounts && sawNoCounts && sawNote && sawTags && sawErrors)
    }

    @Test func randomBytesAndRandomStructureAlwaysParseToASaveableIndex() throws {
        let structure = try FuzzDictionary.strings("archive-index-lines")
        var random = SplitMix64(seed: fuzzSalt ^ 0x1_4DE)
        let alphabet = Array(structure.joined(separator: "\n").utf8)
        for round in 0..<3000 {
            let bytes: [UInt8] =
                round.isMultiple(of: 2)
                ? (0..<Int.random(in: 0...300, using: &random)).map { _ in
                    Bool.random(using: &random)
                        ? alphabet.randomElement(using: &random)!
                        : UInt8.random(in: .min ... .max, using: &random)
                }
                : Array(
                    (0..<Int.random(in: 0...30, using: &random)).map { _ in
                        structure.randomElement(using: &random)!
                    }
                    .joined(separator: "\n").utf8)
            let index = parseIndex(Data(bytes)).index
            #expect(throws: Never.self, "round \(round)") {
                try ArchiveIndexFormat.verifiedSerialization(of: index)
            }
        }
    }

    /// Damage to one section costs at most that section: every section whose lines the
    /// mutation didn't touch reads as before. The one sanctioned exception, as for duplicate
    /// scene ids (§6): a damaged heading that now names an earlier copy takes that copy's place.
    @Test func damageStaysInItsSection() throws {
        let structure = try FuzzDictionary.tokens("archive-index-lines")
        var random = SplitMix64(seed: fuzzSalt ^ 0x10_CA1)
        var checked = 0
        for seed in UInt64(0)..<40 {
            var generator = BookGenerator(seed: seed ^ fuzzSalt ^ 0xA5)
            let original = Array(
                Array(ArchiveIndexFormat.serialize(generator.index())).split(
                    separator: Latin1.newline, omittingEmptySubsequences: false))
            let before = parseIndex(Data(Array(original.joined(separator: [Latin1.newline]))))
            try #require(before.newEntries.isEmpty, "precondition: a canonical index")
            for _ in 0..<100 {
                var lines = original
                let at = Int.random(in: 0..<lines.count, using: &random)
                var touched = at...at
                switch Int.random(in: 0...3, using: &random) {
                case 0: lines.remove(at: at)
                case 1: lines.insert(structure.randomElement(using: &random)![...], at: at)
                case 2:
                    if !lines[at].isEmpty {
                        lines[at][
                            lines[at].startIndex + Int.random(in: 0..<lines[at].count, using: &random)] =
                            UInt8.random(in: .min ... .max, using: &random)
                    }
                default:
                    lines = Array(lines.prefix(at))
                    touched = at...original.count
                }
                let after = parseIndex(Data(Array(lines.joined(separator: [Latin1.newline])))).index
                #expect(throws: Never.self) { try ArchiveIndexFormat.verifiedSerialization(of: after) }
                for copy in before.index.copies {
                    let heading = Array("## \(copy.number.fileName)".utf8)
                    let start = try #require(original.firstIndex { $0.elementsEqual(heading) })
                    let end =
                        original[(start + 1)...].firstIndex { $0.starts(with: Array("## ".utf8)) }
                        ?? original.count
                    guard !touched.overlaps((start - 1)...end),
                        lines.count(where: { $0.elementsEqual(heading) }) == 1
                    else { continue }
                    checked += 1
                    #expect(
                        after.copies.contains(copy), "\(copy.number) changed though line \(at) isn't in it")
                }
            }
        }
        #expect(checked > 2000, "precondition: the property was exercised (\(checked) sections)")
    }
}
