import Foundation
import SceneItTestSupport
import Synchronization
import Testing

@testable import SceneItCore

/// The File Cabinet search's filed copies (#34, PLAN §9.2): read, parsed and indexed the first
/// time they're asked for, only ever read, kept with the book until it closes, and a copy filed
/// once they've been read is read at once. A copy that can't be read is reported, never fatal,
/// and tried again by the next search. Closing the book is final, even mid-read.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FiledCopyIndexesTests {
    static let record = FilingRecord(
        filed: CalendarDay(year: 2026, month: 10, day: 13)!, tags: ["draft 3"], note: "After the restructure."
    )

    /// A book with two scenes, filed once; then the first scene's text changed. The store reads
    /// and writes through `fileSystem`, rooted at the package.
    private func withFiledBook(
        _ body: (
            TestStore, OpenBook<ManualClock>, URL, (ferry: SceneID, letter: SceneID), FaultInjectingFileSystem
        )
            async throws -> Void
    ) async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            let fileSystem = FaultInjectingFileSystem(root: url)
            let store = makeStore(in: folder, fileSystem: fileSystem)
            try #require(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let ferry = try #require(book.write("The ferry left at dawn."))
            let letter = try #require(book.write("He read the letter twice."))
            book.setTitle(of: ferry, to: "The ferry")
            guard case .filed(let outcome) = await store.fileACopy(of: book, as: Self.record),
                outcome.isComplete
            else {
                Issue.record("precondition: a copy is filed, locked and indexed")
                return
            }
            book.replaceBody(of: ferry, with: [[Run("Rewritten since.")]])
            try await body(store, book, url, (ferry, letter), fileSystem)
        }
    }

    private static func units(_ index: FiledCopyIndex?) -> [SearchUnit]? {
        if case .indexed(let search) = index { search.units.map(\.unit) } else { nil }
    }

    private static let firstCopy = FaultInjectingFileSystem.Call.read(
        "Archive/\(FiledCopyNumber.first.fileName)")

    @Test func aCopyIsDecodedIntoItsUnitsOnlyWhenAskedFor() async throws {
        try await withFiledBook { _, book, url, scenes, fileSystem in
            let indexes = try #require(book.filedCopyIndexes)
            #expect(!indexes.isRequested(.first), "nothing is read until a search asks")
            let archive = try DirectorySnapshot(PackageLayout(root: url).archive)
            fileSystem.clearCalls()

            let units = try #require(Self.units(await indexes.index(of: .first)))
            #expect(indexes.isRequested(.first))
            #expect(units.allSatisfy { $0.version == .filed(.first) })
            #expect(
                units.filter { $0.field == .body(paragraph: 0) }.map(\.text)
                    == ["The ferry left at dawn.", "He read the letter twice."],
                "the copy's text, not the book's")
            #expect(units.contains { $0.scene?.id == scenes.ferry && $0.field == .title })
            #expect(fileSystem.calls.filter(\.isMutation).isEmpty, "only read")
            #expect(try DirectorySnapshot(PackageLayout(root: url).archive) == archive)
        }
    }

    @Test func eachCopyIsReadOnce() async throws {
        let reads = Mutex([FiledCopyNumber]())
        let indexes = FiledCopyIndexes { number in
            reads.withLock { $0.append(number) }
            return .indexed(KeywordSearch(units: []))
        }
        let numbers = [FiledCopyNumber(1)!, FiledCopyNumber(2)!]
        indexes.prepare(numbers)
        #expect(numbers.allSatisfy(indexes.isRequested), "a read under way counts")
        for number in numbers + numbers { _ = await indexes.index(of: number) }
        #expect(reads.withLock { $0.sorted() } == numbers)
    }

    /// A copy that can't be read is reported to the search that asked, isn't kept, and is read
    /// again by the next search.
    @Test func aCopyThatFailsIsTriedAgainNextTime() async throws {
        try await withFiledBook { _, book, _, _, fileSystem in
            let indexes = try #require(book.filedCopyIndexes)
            fileSystem.inject(.fail(Self.firstCopy))
            guard case .unreadable = await indexes.index(of: .first) else {
                Issue.record("the failing read is reported")
                return
            }
            #expect(!indexes.isRequested(.first), "a failure isn't kept")
            fileSystem.clearFault()
            #expect(Self.units(await indexes.index(of: .first)) != nil, "read again, and now it reads")
        }
    }

    @Test func aMissingCopyIsUnreadableAndTheOthersStillRead() async throws {
        try await withFiledBook { _, _, url, _, _ in
            let indexes = FiledCopyIndexes(
                layout: PackageLayout(root: url), fileSystem: LocalFileSystem(), defaults: .system)
            guard case .unreadable = await indexes.index(of: try #require(FiledCopyNumber(7))) else {
                Issue.record("a missing copy is unreadable")
                return
            }
            #expect(Self.units(await indexes.index(of: .first)) != nil)
        }
    }

    /// Filing reads the new copy at once (a read under way, before anyone asks for it), but only
    /// once a File Cabinet search has run.
    @Test func aCopyFiledAfterASearchIsReadAtOnce() async throws {
        try await withFiledBook { store, book, _, _, _ in
            let indexes = try #require(book.filedCopyIndexes)
            guard case .filed(let before) = await store.fileACopy(of: book, as: Self.record) else {
                Issue.record("precondition: a second copy is filed")
                return
            }
            #expect(!indexes.isRequested(before.number), "before any search, filing reads nothing")

            _ = await indexes.index(of: .first)
            guard case .filed(let after) = await store.fileACopy(of: book, as: Self.record) else {
                Issue.record("precondition: a third copy is filed")
                return
            }
            #expect(indexes.isRequested(after.number), "filing started the read")
            #expect(!indexes.isRequested(before.number), "only the copy just filed")
            let units = try #require(Self.units(await indexes.index(of: after.number)))
            #expect(units.contains { $0.text == "Rewritten since." }, "the copy just filed")
        }
    }

    @Test func theIndexesGoWhenTheBookCloses() async throws {
        try await withFiledBook { store, book, _, _, _ in
            let indexes = try #require(book.filedCopyIndexes)
            _ = await indexes.index(of: .first)
            #expect(indexes.isRequested(.first))
            #expect(await store.closeBook() == .left)
            #expect(!indexes.isRequested(.first))
            #expect(await indexes.index(of: .first) == nil, "nothing is read once the book has closed")
            #expect(!indexes.isRequested(.first))
        }
    }

    /// Closing the book while a copy is being read is final: the read's result isn't kept, the
    /// search waiting on it is told the book closed, and nothing reads again.
    @Test func closingTheBookMidReadIsFinal() async throws {
        try await withFiledBook { store, book, _, _, fileSystem in
            let indexes = try #require(book.filedCopyIndexes)
            let gate = await Gate()
            fileSystem.before(Self.firstCopy) { gate.pass() }
            let search = Task { await indexes.index(of: .first) }
            await gate.waitForArrival()
            #expect(await store.closeBook() == .left)
            gate.open()
            #expect(await search.value == nil, "the waiting search learns the book closed")
            #expect(!indexes.isRequested(.first), "the read's result isn't kept")
            fileSystem.clearCalls()
            indexes.prepare([.first])
            #expect(await indexes.index(of: .first) == nil)
            #expect(!fileSystem.calls.contains(Self.firstCopy), "nothing reads again")
        }
    }

    /// A result in a filed copy opens the copy at the result's scene, for its window to select.
    @Test func aSearchResultOpensTheCopyAtItsScene() async throws {
        try await withFiledBook { store, book, _, scenes, _ in
            book.select(scenes.ferry)
            let indexes = try #require(book.filedCopyIndexes)
            guard case .indexed(let search) = await indexes.index(of: .first) else {
                Issue.record("precondition: the copy is read")
                return
            }
            var last: SearchUpdate?
            for await update in search.search(SearchQuery("letter")) { last = update }
            let hit = try #require(last?.scenes.first?.best)
            #expect(hit.unit.scene?.id == scenes.letter, "precondition: the hit is in another scene")

            #expect(await store.openFiledCopy(.first, of: book, showing: hit) == .opened)
            let copy = try #require(store.shown)
            #expect(copy !== book)
            #expect(copy.openScene == scenes.letter)
            #expect(copy.searchVersion == .filed(.first))
            #expect(book.searchVersion == .working)
            #expect(copy.filedCopyIndexes == nil, "a filed copy has no File Cabinet")
            #expect(copy.takeSearchArrival() == hit)
            #expect(copy.takeSearchArrival() == nil, "taken once")
            #expect(book.openScene == scenes.ferry, "the book keeps its scene for Close")
        }
    }
}
