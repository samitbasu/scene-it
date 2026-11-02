import Foundation
import Testing

@testable import SceneItCore

/// The day a section with no valid `filed` line gets: one per copy, so a test can tell
/// which copy's default it is.
private func modifiedDay(_ number: FiledCopyNumber) -> CalendarDay {
    CalendarDay(year: 2026, month: 3, day: 1 + number.value % 28)!
}

private func parseIndex(_ data: Data) -> ParsedArchiveIndex {
    ArchiveIndexFormat.parse(data, filed: modifiedDay)
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

/// Book format §8.
@Suite struct ArchiveIndexTests {
    /// §8's example, verbatim.
    static let example = """
        ---
        format: 2
        ---

        ## save0001.md
        filed: 2026-09-14
        tags: first draft
        scenes: 22
        words: 48210
        comments: 31

        ## save0002.md
        filed: 2026-10-31
        tags: draft 4, before the ending
        note: Before the ending rewrite
        scenes: 24
        words: 51336
        comments: 44

        """

    @Test func theSpecExampleReadsAsWrittenAndIsCanonical() throws {
        let parsed = parseIndex(Self.example)
        #expect(parsed.newEntries.isEmpty)
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
        #expect(serialized(parsed.index) == Self.example)
    }

    @Test func anEmptyIndexIsJustTheFrontMatterAndItIsWhatANewPackageHolds() {
        #expect(serialized(ArchiveIndex()) == "---\nformat: 2\n---\n")
        #expect(BookPackage.emptyArchiveIndex == ArchiveIndexFormat.serialize(ArchiveIndex()))
        let parsed = parseIndex(BookPackage.emptyArchiveIndex)
        #expect(parsed.index == ArchiveIndex() && parsed.newEntries.isEmpty)
    }

    // MARK: §8's rules, row by row

    @Test func frontMatterHoldsOnlyTheFormat() {
        let missing = parseIndex("## save0001.md\nfiled: 2026-01-01\n")
        #expect(missing.index.errors == [RepairNotice.missingFormat.entry])
        #expect(missing.newEntries == [RepairNotice.missingFormat.entry])

        let extra = parseIndex("---\nformat: 2\ntitle: Novel\nformat: 2\n---\n")
        #expect(
            extra.index.errors == [
                ErrorEntry(.frontMatter, "title: Novel"), ErrorEntry(.frontMatter, "format: 2"),
            ])

        let other = parseIndex("---\nformat: 3\n---\n")
        #expect(other.index.errors == [RepairNotice.otherFormat(3).entry])
    }

    @Test(arguments: [
        "save1.md", "save001.md", "save0001.MD", "Save0001.md", "save0001.md.bak", "save00001.md",
        "save-001.md",
        "index.md", "",
    ])
    func anyOtherSectionHeadingIsALineAndSoAreTheLinesUnderIt(_ name: String) {
        let text =
            "---\nformat: 2\n---\n\n## \(name)\nfiled: 2026-01-01\n\n## save0002.md\nfiled: 2026-02-02\n"
        let parsed = parseIndex(text)
        let heading = name.isEmpty ? "##" : "## \(name)"
        #expect(parsed.index.copies.map(\.number) == [copy(2)])
        #expect(parsed.index.errors == [ErrorEntry(.line, heading), ErrorEntry(.line, "filed: 2026-01-01")])
        #expect(parsed.newEntries == parsed.index.errors)
    }

    @Test func aSecondSectionForTheSameCopyIsLinesAndTheFirstWins() throws {
        let parsed = parseIndex(
            "---\nformat: 2\n---\n\n## save0001.md\nfiled: 2026-01-01\n\n## save0001.md\nfiled: 2026-09-09\nnote: x\n"
        )
        #expect(parsed.index.copies.map(\.filed) == [try day("2026-01-01")])
        #expect(
            parsed.index.errors == [
                ErrorEntry(.line, "## save0001.md"), ErrorEntry(.line, "filed: 2026-09-09"),
                ErrorEntry(.line, "note: x"),
            ])
    }

    @Test func aMissingFiledDateIsTheCopysModificationDayWithANotice() throws {
        let parsed = parseIndex("---\nformat: 2\n---\n\n## save0005.md\nscenes: 1\n")
        let filed = modifiedDay(copy(5))
        #expect(parsed.index.copies.map(\.filed) == [filed])
        #expect(parsed.index.copies[0].errors == [RepairNotice.missingFiledDate(setTo: filed).entry])
        #expect(
            parsed.index.copies[0].errors[0].payload
                == "This filed copy had no filed date, so it was set to 2026-03-06.")
    }

    @Test(arguments: [
        "2026-13-01", "2026-02-30", "2026-1-01", "26-01-01", "2026-01-01T00:00:00", "yesterday", "",
    ])
    func aBadFiledDateIsAMetadataEntryAndTheModificationDayWithoutANotice(_ value: String) {
        let line = value.isEmpty ? "filed:" : "filed: \(value)"
        let parsed = parseIndex("---\nformat: 2\n---\n\n## save0007.md\n\(line)\n")
        #expect(parsed.index.copies.map(\.filed) == [modifiedDay(copy(7))])
        #expect(parsed.index.copies[0].errors == [ErrorEntry(.metadata, line)])
    }

    @Test func countsAreACacheSoMissingOrBadOnesAreDroppedSilently() {
        for counts in [
            "scenes: 1\nwords: 2", "scenes: 1\nwords: x\ncomments: 3", "scenes: -1\nwords: 2\ncomments: 3",
        ] {
            let parsed = parseIndex("---\nformat: 2\n---\n\n## save0001.md\nfiled: 2026-01-01\n\(counts)\n")
            #expect(parsed.index.copies[0].counts == nil, "\(counts)")
            #expect(parsed.newEntries.isEmpty, "\(counts)")
        }
        let parsed = parseIndex(
            "---\nformat: 2\n---\n\n## save0001.md\nfiled: 2026-01-01\nwords: 2\ncomments: 3\nscenes: 1\n")
        #expect(parsed.index.copies[0].counts == FiledCopyCounts(scenes: 1, words: 2, comments: 3))
    }

    @Test func unknownAndDuplicateKeysAreMetadataEntriesOfTheirSection() {
        let parsed = parseIndex(
            "---\nformat: 2\n---\n\n## save0001.md\nfiled: 2026-01-01\ncolor: red\nnote: one\nnote: two\nNote: three\n"
        )
        #expect(parsed.index.copies[0].note == "one")
        #expect(
            parsed.index.copies[0].errors == [
                ErrorEntry(.metadata, "color: red"), ErrorEntry(.metadata, "note: two"),
                ErrorEntry(.metadata, "Note: three"),
            ])
    }

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

    @Test func unparsedEntriesArePreservedAndOtherLinesBecomeEntriesWhereTheyAre() {
        let text = """
            ---
            format: 2
            ---
            stray before

            ### Unparsed
            - [line] kept
            - [foo] wrapped

            ## save0001.md
            filed: 2026-01-01
            not a key
            #### Heading

            ### Unparsed
            - [metadata] colour: red
            loose
            """
        let parsed = parseIndex(text)
        #expect(
            parsed.index.errors == [
                ErrorEntry(.line, "stray before"), ErrorEntry(.line, "kept"),
                ErrorEntry(.line, "- [foo] wrapped"),
            ])
        #expect(
            parsed.index.copies[0].errors == [
                ErrorEntry(.line, "not a key"), ErrorEntry(.line, "#### Heading"),
                ErrorEntry(.metadata, "colour: red loose"),
            ])
        #expect(
            parsed.newEntries == [
                ErrorEntry(.line, "stray before"), ErrorEntry(.line, "- [foo] wrapped"),
                ErrorEntry(.line, "not a key"),
                ErrorEntry(.line, "#### Heading"),
            ])
        let saved = try! ArchiveIndexFormat.verifiedSerialization(of: parsed.index)
        #expect(parseIndex(saved).newEntries.isEmpty, "a saved index has nothing new to report")
    }

    @Test func sectionsAreReadInAnyOrderAndWrittenInAscendingOrder() {
        let parsed = parseIndex(
            "---\nformat: 2\n---\n\n## save0010.md\nfiled: 2026-01-10\n\n## save0002.md\nfiled: 2026-01-02\n")
        #expect(parsed.index.copies.map(\.number) == [copy(2), copy(10)])
        #expect(parsed.newEntries.isEmpty)
        #expect(
            serialized(parsed.index).firstRange(of: "save0002")!.lowerBound
                < serialized(parsed.index).firstRange(of: "save0010")!.lowerBound)
    }

    @Test func charactersAreAdmittedAsInTheBookWithANoticePerSection() {
        let parsed = parseIndex(
            Data("---\nformat: 2\n---\n\n## save0001.md\nfiled: 2026-01-01\nnote: “wave” 🌊\n".utf8))
        #expect(parsed.index.copies[0].note == "\"wave\" [?]")
        #expect(parsed.index.copies[0].errors == [RepairNotice.replacedCharacters(["\u{1F30A}"]).entry])
        #expect(parsed.index.errors.isEmpty)
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

    private static let structure = [
        "---", "format: 2", "format: x", "title: T", "", "## save0001.md", "## save0002.md", "## save1.md",
        "## Notes", "### Unparsed", "### unparsed", "filed: 2026-01-01", "filed: soon", "tags: a, b",
        "note: n",
        "scenes: 1", "words: 2", "comments: 3", "- [line] x", "- [notice] y", "- [bad] z", "continued", "-",
        "\u{1F30A}", "\\",
    ]

    @Test func randomBytesAndRandomStructureAlwaysParseToASaveableIndex() throws {
        var random = SplitMix64(seed: fuzzSalt ^ 0x1_4DE)
        let alphabet = Array(Self.structure.joined(separator: "\n").utf8)
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
                        Self.structure.randomElement(using: &random)!
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
                case 1: lines.insert(Array(Self.structure.randomElement(using: &random)!.utf8)[...], at: at)
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
