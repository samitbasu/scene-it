import Foundation
import Testing

@testable import SceneItCore

/// What ADR 0024 needs from a parse: the entries it made, apart from those the file
/// already held in `### Unparsed`.
@Suite struct NewEntryTests {
    @Test func preservedEntriesAreNotNew() throws {
        let parsed = parse(try Fixture.data("complete-example"))
        #expect(parsed.book.errorEntries.joined().count == 3, "precondition: the file holds entries")
        #expect(parsed.newEntries.isEmpty)
        #expect(!parsed.wasRepaired)
    }

    @Test func everyEntryOfADamagedFileIsNew() throws {
        let parsed = parse(try SpecExampleTests.damagedBytes())
        #expect(parsed.newEntries == Array(parsed.book.errorEntries.joined()))
        #expect(parsed.wasRepaired)
    }

    @Test func aMalformedUnparsedLineIsNewButAWellFormedOneIsNot() {
        let parsed = parse(file(scene: "Text.\n\n### Unparsed\n- [line] kept\n- [foo] x\nstray"))
        #expect(
            parsed.book.scenes[0].errors == [
                ErrorEntry(.line, "kept"), ErrorEntry(.line, "- [foo] x stray"),
            ])
        #expect(parsed.newEntries == [ErrorEntry(.line, "- [foo] x stray")])
    }

    @Test func aSavedBookReadsBackWithNoNewEntries() throws {
        let book = parse(try SpecExampleTests.damagedBytes()).book
        let reread = parse(try BookFormat.verifiedSerialization(of: book))
        #expect(reread.newEntries.isEmpty, "next time it opens, nothing is repaired")
        #expect(reread.book == book)
    }
}
