import Foundation
import Testing

@testable import SceneItCore

/// Launch reconciliation as a pure function (PLAN §5.5, book format §8).
@Suite struct ArchiveReconciliationTests {
    static let fileDay = CalendarDay(year: 2026, month: 10, day: 1)!

    static func number(_ value: Int) -> FiledCopyNumber { FiledCopyNumber(value)! }

    static func files(_ numbers: Int...) -> [DirectoryEntry] {
        numbers.map { DirectoryEntry(name: number($0).fileName, kind: .file) }
    }

    static func parse(_ text: String) -> ParsedArchiveIndex {
        ArchiveIndexFormat.parse(Data(text.utf8), filed: { _ in fileDay })
    }

    static let counted = FiledCopyCounts(scenes: 3, words: 120, comments: 2)!

    static func reconcile(
        _ listing: [DirectoryEntry], _ index: ParsedArchiveIndex, counts: FiledCopyCounts? = counted
    ) -> ReconciledArchive {
        ArchiveReconciliation.reconcile(
            listing: listing, index: index, modified: { _ in fileDay }, counts: { _ in counts }, pending: [:],
            digest: { _ in nil })
    }

    static let twoCopies = """
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

    @Test func anIndexThatMatchesTheFilesIsLeftAsItIs() {
        let parsed = Self.parse(Self.twoCopies)
        #expect(parsed.newEntries.isEmpty, "precondition: the index is clean")
        let reconciled = Self.reconcile(Self.files(1, 2), parsed)
        #expect(reconciled.index == parsed.index)
        #expect(reconciled.notices.isEmpty)
        #expect(reconciled.rewrite == .unneeded)
        #expect(reconciled.next == Self.number(3))
    }

    @Test func aFiledCopyWithNoEntryIsListedWithNoTagsAndItsCounts() throws {
        let parsed = Self.parse(Self.twoCopies)
        let reconciled = Self.reconcile(Self.files(1, 2, 3), parsed)
        #expect(reconciled.index.copies.map(\.number) == [1, 2, 3].map(Self.number))
        let added = try #require(reconciled.index.copies.last)
        #expect(added == FiledCopy(number: Self.number(3), filed: Self.fileDay, counts: Self.counted))
        #expect(added.tags.isEmpty && added.note.isEmpty)
        #expect(reconciled.notices == [.listedWithoutEntry(Self.number(3))])
        #expect(reconciled.rewrite == .needed)
        #expect(reconciled.index.copies.prefix(2) == parsed.index.copies[...], "the others are untouched")
    }

    @Test func anEntryWhoseFileIsMissingIsUnlistedAndKeptAsUnparsedLines() throws {
        let parsed = Self.parse(Self.twoCopies)
        let reconciled = Self.reconcile(Self.files(2), parsed)
        #expect(reconciled.index.copies.map(\.number) == [Self.number(2)])
        #expect(reconciled.notices == [.keptEntryWithoutFile(Self.number(1))])
        #expect(reconciled.rewrite == .neededKeepingOriginal, "the writer's section is rewritten")
        #expect(
            reconciled.index.errors
                == [
                    "## save0001.md", "filed: 2026-09-14", "tags: first draft", "scenes: 22", "words: 48210",
                    "comments: 31",
                ].map { ErrorEntry(.line, $0) })
        let bytes = try ArchiveIndexFormat.verifiedSerialization(of: reconciled.index)
        let reread = ArchiveIndexFormat.parse(bytes, filed: { _ in Self.fileDay })
        #expect(reread.newEntries.isEmpty, "the kept lines read back as entries already kept")
        #expect(Self.reconcile(Self.files(2), reread).rewrite == .unneeded, "kept once")
    }

    /// A parse that repaired something (a missing filed date) reads as what would be written,
    /// but its notice is new: the index is still rewritten, keeping the original, so the notice
    /// is new only once.
    @Test func aRepairedIndexIsRewrittenEvenWhenItReadsTheSame() throws {
        let missingDate = "---\nformat: 2\n---\n\n## save0001.md\nscenes: 3\nwords: 120\ncomments: 2\n"
        let parsed = Self.parse(missingDate)
        #expect(!parsed.newEntries.isEmpty, "precondition: the parse made a notice")
        let reconciled = Self.reconcile(Self.files(1), parsed)
        #expect(reconciled.index == parsed.index, "precondition: it reads as what would be written")
        #expect(reconciled.rewrite == .neededKeepingOriginal)
        let rewritten = ArchiveIndexFormat.parse(
            try ArchiveIndexFormat.verifiedSerialization(of: reconciled.index), filed: { _ in Self.fileDay })
        #expect(rewritten.newEntries.isEmpty, "once written, the notice is kept, not new")
        #expect(Self.reconcile(Self.files(1), rewritten).rewrite == .unneeded)
    }

    static let filedBytes = ContentDigest(Data("the copy as filed".utf8))

    @Test func aPendingRecordGivesACopyWithNoEntryItsTagsNoteAndDate() throws {
        let record = FilingRecord(
            filed: try #require(CalendarDay(year: 2026, month: 11, day: 2)), tags: ["draft 5"], note: "Kept")
        let pending = PendingRecord(record, copy: Self.filedBytes)
        let reconciled = ArchiveReconciliation.reconcile(
            listing: Self.files(1, 2, 3), index: Self.parse(Self.twoCopies), modified: { _ in Self.fileDay },
            counts: { _ in Self.counted }, pending: [Self.number(3): pending, Self.number(1): pending],
            digest: { _ in Self.filedBytes })
        #expect(
            reconciled.index.copies.last
                == FiledCopy(
                    number: Self.number(3), filed: record.filed, tags: record.tags, note: record.note,
                    counts: Self.counted))
        #expect(
            reconciled.index.copies.first == Self.parse(Self.twoCopies).index.copies.first, "an entry wins")
        #expect(reconciled.notices == [.recordedPendingEntry(Self.number(3))])
    }

    /// Another Mac or a sync tool replaced `Archive/`, so a different file has the record's number,
    /// or the file can't be read to tell.
    @Test(arguments: [ContentDigest(Data("another copy".utf8)), nil])
    func aPendingRecordForAnotherFileAtItsNumberIsntGivenToIt(_ onDisk: ContentDigest?) throws {
        let record = FilingRecord(
            filed: try #require(CalendarDay(year: 2026, month: 11, day: 2)), tags: ["mine"])
        let reconciled = ArchiveReconciliation.reconcile(
            listing: Self.files(1, 2, 3), index: Self.parse(Self.twoCopies), modified: { _ in Self.fileDay },
            counts: { _ in Self.counted },
            pending: [Self.number(3): PendingRecord(record, copy: Self.filedBytes)],
            digest: { _ in onDisk })
        #expect(
            reconciled.index.copies.last
                == FiledCopy(number: Self.number(3), filed: Self.fileDay, counts: Self.counted))
        #expect(reconciled.notices == [.pendingEntryForAnotherCopy(Self.number(3))])
        #expect(reconciled.rewrite == .needed)
    }

    @Test func aNumberPastTheHighestIsNotCountedAndDoesntBlockNumbering() {
        let huge = DirectoryEntry(name: "save\(Int.max).md", kind: .file)
        let reconciled = Self.reconcile([huge] + Self.files(4), Self.parse("---\nformat: 2\n---\n"))
        #expect(reconciled.index.copies.map(\.number) == [Self.number(4)])
        #expect(reconciled.next == Self.number(5))
        #expect(reconciled.notices.first == .numberOutOfRange(FiledCopyNumber(Int.max)!))
        #expect(Self.reconcile(Self.files(999_999), Self.parse("")).next == nil)
        #expect(Self.reconcile(Self.files(999_998), Self.parse("")).next == FiledCopyNumber.highest)
    }

    @Test func numberingIsOneMoreThanTheHighestFileWhateverTheGapsAndEntries() {
        let parsed = Self.parse(Self.twoCopies + "\n## save0009.md\nfiled: 2026-11-01\n")
        #expect(parsed.index.copies.count == 3, "precondition: an entry for save0009.md")
        #expect(Self.reconcile(Self.files(1, 2, 5), parsed).next == Self.number(6))
        #expect(Self.reconcile(Self.files(7), parsed).next == Self.number(8))
        #expect(Self.reconcile([], parsed).next == Self.number(1), "no files: an entry doesn't count")
        #expect(Self.reconcile(Self.files(10_000), parsed).next == Self.number(10_001))
        #expect(ArchiveReconciliation.next(after: [FiledCopyNumber(Int.max)!]) == nil)
    }

    @Test func onlyRegularFilesNamedExactlySaveNNNNmdAreFiledCopies() {
        let junk: [DirectoryEntry] = [
            .init(name: "index.md", kind: .file),
            .init(name: "save1.md", kind: .file),
            .init(name: "save001.md", kind: .file),
            .init(name: "save00012.md", kind: .file),
            .init(name: "SAVE0003.md", kind: .file),
            .init(name: "save0003.MD", kind: .file),
            .init(name: "save0003.md.bak", kind: .file),
            .init(name: "save0003.json", kind: .file),
            .init(name: ".save0003.md.\(UUID().uuidString).tmp", kind: .file),
            .init(name: "save-003.md", kind: .file),
            .init(name: "save0004.md", kind: .directory),
            .init(name: "save0005.md", kind: .symbolicLink),
            .init(name: "save0006.md", kind: .other),
            .init(name: ".DS_Store", kind: .file),
        ]
        let reconciled = Self.reconcile(junk, Self.parse("---\nformat: 2\n---\n"))
        #expect(reconciled.index.copies.isEmpty)
        #expect(reconciled.notices.isEmpty)
        #expect(reconciled.next == Self.number(1))
        #expect(ArchiveReconciliation.filedCopies(in: junk + Self.files(12)) == [Self.number(12)])
    }

    @Test func missingCountsAreComputedAndKeptCountsAreNot() throws {
        let parsed = Self.parse("---\nformat: 2\n---\n\n## save0001.md\nfiled: 2026-09-14\nscenes: 4\n")
        #expect(parsed.index.copies.first?.counts == nil, "precondition: a count is missing")
        let reconciled = Self.reconcile(Self.files(1), parsed)
        #expect(reconciled.index.copies.first?.counts == Self.counted)
        #expect(reconciled.rewrite == .needed)
        #expect(reconciled.notices.isEmpty, "counts are a cache, recomputed silently")

        let kept = Self.reconcile(Self.files(1, 2), Self.parse(Self.twoCopies), counts: nil)
        #expect(kept.index.copies.map(\.counts) == Self.parse(Self.twoCopies).index.copies.map(\.counts))
    }

    @Test func aCopyWhoseCountsCantBeComputedIsStillListed() {
        let reconciled = Self.reconcile(Self.files(1), Self.parse("---\nformat: 2\n---\n"), counts: nil)
        #expect(reconciled.index.copies.map(\.number) == [Self.number(1)])
        #expect(reconciled.index.copies.first?.counts == nil)
    }

    @Test func anIndexFromANewerVersionIsListedButNeverRewritten() {
        let newer = Self.twoCopies.replacingOccurrences(of: "format: 2", with: "format: 3")
        let parsed = Self.parse(newer)
        #expect(parsed.isNewerThanSupported, "precondition")
        let reconciled = Self.reconcile(Self.files(2, 3), parsed)
        #expect(reconciled.rewrite == .refused(newerFormat: FormatVersion(3)))
        #expect(
            reconciled.notices == [
                .indexFromNewerVersion(FormatVersion(3)), .keptEntryWithoutFile(Self.number(1)),
                .listedWithoutEntry(Self.number(3)),
            ])
        #expect(
            reconciled.index.copies.map(\.number) == [2, 3].map(Self.number), "what's listed is reconciled")
    }

    @Test func theIndexsOwnErrorEntriesAreKept() {
        let parsed = Self.parse("---\nformat: 2\n---\n\nA stray line.\n")
        #expect(!parsed.index.errors.isEmpty, "precondition: the index has an entry of its own")
        let reconciled = Self.reconcile(Self.files(1), parsed)
        #expect(reconciled.index.errors == parsed.index.errors)
    }

    @Test func theResultIsInAscendingOrderAndSerializesStably() throws {
        let reconciled = Self.reconcile(Self.files(12, 3, 7), Self.parse(Self.twoCopies))
        #expect(reconciled.index.copies.map(\.number) == [3, 7, 12].map(Self.number))
        let bytes = try ArchiveIndexFormat.verifiedSerialization(of: reconciled.index)
        #expect(ArchiveIndexFormat.parse(bytes, filed: { _ in Self.fileDay }).index == reconciled.index)
    }
}
