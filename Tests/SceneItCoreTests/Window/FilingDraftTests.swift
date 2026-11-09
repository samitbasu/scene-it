import Foundation
import Testing

@testable import SceneItCore

@Suite struct FilingDraftTests {
    static let today = CalendarDay(year: 2026, month: 11, day: 3)!

    @Test func returnMakesTheTypedTextATag() {
        var draft = FilingDraft(today: Self.today)
        draft.pendingTag = "  draft 4 "
        draft.commitPendingTag()
        draft.pendingTag = "before the ending"
        draft.commitPendingTag()
        #expect(draft.tags == ["draft 4", "before the ending"])
        #expect(draft.pendingTag.isEmpty)
    }

    @Test func emptyAndRepeatedTagsAreIgnored() {
        var draft = FilingDraft(today: Self.today)
        for typed in ["", "   ", "draft 4", "draft 4"] {
            draft.pendingTag = typed
            draft.commitPendingTag()
        }
        #expect(draft.tags == ["draft 4"])
        #expect(draft.pendingTag.isEmpty)
    }

    /// The Tags tab's reading of a typed tag (#20): one leading `#` dropped, and a tag the
    /// draft has in another case is the same tag.
    @Test func aTypedTagIsReadAsTheTagsTabReadsIt() {
        var draft = FilingDraft(today: Self.today)
        for typed in ["#draft 4", "DRAFT 4", " # ", "##ending"] {
            draft.pendingTag = typed
            draft.commitPendingTag()
        }
        #expect(draft.tags == ["draft 4", "#ending"])
    }

    @Test func tagsAreAdmittedAsOneLine() {
        var draft = FilingDraft(today: Self.today)
        draft.pendingTag = "draft\n4"
        draft.commitPendingTag()
        #expect(draft.tags == ["draft 4"])
    }

    @Test func tagsAndTheNoteAreTransliteratedToASCII() {
        var draft = FilingDraft(today: Self.today)
        draft.pendingTag = "caf\u{E9} \u{2014} \u{1F3AC}"
        draft.note = "\u{201C}Na\u{EF}ve\u{201D}\r\nend\u{2026}"
        #expect(draft.pendingTag == "cafe -- [?]")
        #expect(draft.note == "\"Naive\"\nend...")
        draft.commitPendingTag()
        #expect(draft.record.tags == ["cafe -- [?]"])
    }

    @Test func deleteRemovesTheLastTagOnlyWhileNothingIsTyped() {
        var draft = FilingDraft(today: Self.today)
        for tag in ["one", "two"] {
            draft.pendingTag = tag
            draft.commitPendingTag()
        }
        draft.pendingTag = "th"
        var removed = draft.deleteBackward()
        #expect(!removed)
        #expect(draft.tags == ["one", "two"])
        draft.pendingTag = ""
        var removals: [Bool] = []
        for _ in 0..<3 {
            removed = draft.deleteBackward()
            removals.append(removed)
        }
        #expect(removals == [true, true, false])
        #expect(draft.tags.isEmpty)
    }

    @Test func aChipsCrossRemovesThatTag() {
        var draft = FilingDraft(today: Self.today)
        for tag in ["one", "two", "three"] {
            draft.pendingTag = tag
            draft.commitPendingTag()
        }
        draft.remove("two")
        #expect(draft.tags == ["one", "three"])
    }

    @Test func theRecordIsDatedTodayByDefaultAndCountsATagStillBeingTyped() {
        var draft = FilingDraft(today: Self.today)
        draft.pendingTag = "draft 4"
        draft.note = "Before the ending rewrite"
        #expect(
            draft.record
                == FilingRecord(filed: Self.today, tags: ["draft 4"], note: "Before the ending rewrite"))
        draft.filed = CalendarDay(year: 2026, month: 10, day: 31)!
        #expect(draft.record.filed == CalendarDay(year: 2026, month: 10, day: 31))
    }

    @Test func noonIsThatDayInTheZone() throws {
        for identifier in ["America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Pago_Pago", "UTC"] {
            let zone = try #require(TimeZone(identifier: identifier))
            for day in [
                Self.today, CalendarDay(year: 2026, month: 3, day: 8)!,
                CalendarDay(year: 2026, month: 11, day: 1)!,
            ] {
                #expect(CalendarDay(day.noon(in: zone), in: zone) == day, "\(identifier) \(day)")
            }
        }
    }
}
