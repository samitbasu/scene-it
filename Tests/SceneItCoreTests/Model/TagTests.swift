import Foundation
import Testing

@testable import SceneItCore

/// Tags are single-line (ADR 0033), as a title is, so search's `\n` tag separator is exact.
@Suite struct TagTests {
    private static let created = Timestamp(secondsSince1970: 0, offset: .zero)

    @Test(arguments: lineBreaks)
    func aLineBreakInASceneTagBecomesASpace(separator: String) {
        var scene = BookScene(
            id: SceneID(rawValue: "s1"), modified: Self.created, title: "T",
            tags: ["red\(separator)door", "\(separator)"])
        #expect(scene.tags == ["red door", " "])
        scene.tags = ["blue\(separator)sky"]
        #expect(scene.tags == ["blue sky"], "assignment applies the policy too")
    }

    @Test(arguments: lineBreaks)
    func aLineBreakInAFiledCopyTagBecomesASpace(separator: String) throws {
        let day = try #require(CalendarDay(year: 2026, month: 1, day: 1))
        var copy = FiledCopy(
            number: try #require(FiledCopyNumber(1)), filed: day, tags: ["draft\(separator)4"])
        #expect(copy.tags == ["draft 4"])
        copy.tags = ["before\(separator)the end"]
        #expect(copy.tags == ["before the end"])
    }

    /// Typing and pasting are never noticed (ADR 0028), but a line break read from the file is a
    /// repair, so the book opens as repaired (ADR 0024).
    @Test func anEscapedLineBreakInASceneTagIsARepair() throws {
        let parsed = parse(
            "---\ntitle: T\nformat: 2\n---\n\n## S\nid: s1\nmodified: 2026-01-01T00:00:00+00:00\n"
                + "tags: red\\ndoor, b\n\nBody.\n")
        let scene = try #require(parsed.book.scenes.first)
        #expect(scene.tags == ["red door", "b"])
        let notice = RepairNotice.lineBreaksInTags(.scene).entry
        #expect(parsed.newEntries == [notice])
        #expect(scene.errors == [notice])
        #expect(parsed.wasRepaired)
        #expect(serialized(parsed.book).contains("tags: red door, b\n"))
    }

    @Test func anEscapedBackslashBeforeNIsNotALineBreak() throws {
        let parsed = parse(
            "---\ntitle: T\nformat: 2\n---\n\n## S\nid: s1\nmodified: 2026-01-01T00:00:00+00:00\n"
                + "tags: a\\\\nb\n\nBody.\n")
        #expect(parsed.book.scenes.first?.tags == ["a\\nb"])
        #expect(!parsed.wasRepaired)
    }

    @Test func anEscapedLineBreakInAFiledCopyTagIsARepair() throws {
        let parsed = ArchiveIndexFormat.parse(
            Data("---\nformat: 2\n---\n\n## save0001.md\nfiled: 2026-09-14\ntags: first\\ndraft\n".utf8),
            filed: Corpus.filedDay)
        let copy = try #require(parsed.index.copies.first)
        #expect(copy.tags == ["first draft"])
        #expect(parsed.newEntries == [RepairNotice.lineBreaksInTags(.filedCopy).entry])
    }
}
