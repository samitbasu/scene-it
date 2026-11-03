import Foundation
import Testing

@testable import SceneItCore

/// What ADR 0024 needs from a parse: the entries it made, apart from those the file
/// already held in `### Unparsed`. Every corpus case's `entries.txt` says which entries are new.
@Suite struct NewEntryTests {
    @Test func preservedEntriesAreNotNew() throws {
        let parsed = try parse(case: "s9.1-complete-book")
        #expect(parsed.book.errorEntries.joined().count == 3, "precondition: the file holds entries")
        #expect(parsed.newEntries.isEmpty)
        #expect(!parsed.wasRepaired)
    }

    @Test func everyEntryOfADamagedFileIsNew() throws {
        let parsed = parse(try SpecExampleTests.damagedBytes())
        #expect(parsed.newEntries == Array(parsed.book.errorEntries.joined()))
        #expect(parsed.wasRepaired)
    }

    @Test func aSavedBookReadsBackWithNoNewEntries() throws {
        let book = parse(try SpecExampleTests.damagedBytes()).book
        let reread = parse(try BookFormat.verifiedSerialization(of: book))
        #expect(reread.newEntries.isEmpty, "next time it opens, nothing is repaired")
        #expect(reread.book == book)
    }
}
