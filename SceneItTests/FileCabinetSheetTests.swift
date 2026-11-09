import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

private let ferry = scene("The ferry", [[Run("The ferry left at dawn. Mara watched.")]])

/// The File Cabinet sheet (#33) in the real window, over a book with three filed copies: its
/// cards, newest first; the search field; a card's clicks (ADR 0046); + tag and × on a card, which
/// rewrite only `Archive/index.md`; and a read-only book's cards.
///
/// SwiftUI exposes no accessibility tree offscreen, so the cards and chips are exercised through the
/// `FileCabinetActions` their buttons call, made from the window's own book and sheet model; the
/// search and + tag fields are the window's own, driven through their field editors.
extension OneAtATime {
    @Suite(.serialized, .timeLimit(.minutes(2)))
    @MainActor
    struct FileCabinetSheetTests {
        static func day(_ month: Int, _ day: Int) -> CalendarDay {
            CalendarDay(year: 2026, month: month, day: day)!
        }

        static let records = [
            FilingRecord(filed: day(7, 14), tags: ["draft 2"], note: "Before cutting the brother subplot."),
            FilingRecord(
                filed: day(10, 30), tags: ["beta readers", "draft 3"], note: "Sent to the beta readers."),
            FilingRecord(filed: day(9, 17), tags: ["contest"], note: "Submitted to the contest."),
        ]

        @Test func theCardsAreTheCopiesNewestFirst() async throws {
            try await withCabinet { harness, _, _ in
                #expect(
                    FileCabinet.cards(of: harness.book.archive, harness.cabinet.filter).map(\.number.value)
                        == [2, 3, 1])
                #expect(harness.searchField != nil, "the filters show while there are copies")
            }
        }

        @Test func theSearchFieldShowsTheCopiesWhoseTagsOrNoteMatch() async throws {
            try await withCabinet { harness, _, _ in
                let field = try #require(harness.searchField, "precondition: the search field")
                #expect(harness.window.makeFirstResponder(field))
                let editor = try #require(field.currentEditor() as? NSTextView)
                @MainActor func search(_ text: String) async -> [Int] {
                    editor.selectAll(nil)
                    editor.insertText(text, replacementRange: editor.selectedRange())
                    await eventually { harness.cabinet.filter.words == text }
                    return FileCabinet.cards(of: harness.book.archive, harness.cabinet.filter).map(
                        \.number.value)
                }
                #expect(await search("draft") == [2, 1])
                #expect(await search("BETA sent") == [2])
                #expect(await search("lighthouse") == [])
                harness.modes.mode = .page
                await eventually { harness.cabinet.filter.isEmpty }
            }
        }

        /// A double click arrives as two clicks: the first selects the card, the second opens the
        /// copy. A second click on another card only selects that one; Return (`CardKey.open`)
        /// opens the selection.
        @Test func aClickSelectsACardAndADoubleClickOpensItsCopy() async throws {
            try await withCabinet { harness, actions, opened in
                let first = try #require(FiledCopyNumber(1))
                let second = try #require(FiledCopyNumber(2))
                actions.click(.single, on: first)
                #expect(harness.cabinet.selected == first)
                await eventually { harness.window.firstResponder === harness.cabinet.keyFocus.view }
                #expect(
                    harness.window.firstResponder === harness.cabinet.keyFocus.view,
                    "the sheet takes the keys")
                actions.click(.double, on: second)
                #expect(opened.numbers.isEmpty, "the first click landed on another card")
                #expect(harness.cabinet.selected == second)
                actions.click(.double, on: second)
                #expect(opened.numbers == [second])
                #expect(actions.handle(.open) == .handled)
                #expect(opened.numbers == [second, second], "Return opens the selected card")
            }
        }

        /// + tag on a card, through the window's own field: Return adds the tag to the copy's record
        /// in `Archive/index.md` and keeps the field open; × takes one off. The filed copy is never
        /// written: its bytes, modification time and locked flag are as they were.
        @Test func aCardsTagsChangeOnlyTheIndex() async throws {
            try await withCabinet { harness, actions, _ in
                let copy = try #require(FiledCopyNumber(1))
                let file = PackageLayout(root: harness.url).filedCopy(copy)
                let before = try Fingerprint(file)
                try #require(before.locked, "precondition: the copy is locked")

                actions.startTagging(copy)
                let field = try await harness.cabinetTagField()
                let editor = try #require(field.currentEditor() as? NSTextView)
                editor.insertText("#Beta", replacementRange: editor.selectedRange())
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                await eventually { harness.tags(copy) == ["draft 2", "Beta"] }
                #expect(harness.tags(copy) == ["draft 2", "Beta"], "without the #")
                #expect(harness.cabinet.tagging == copy, "Return keeps the field open")
                #expect(
                    try harness.indexOnDisk().copies.first { $0.number == copy }?.tags == ["draft 2", "Beta"])

                actions.removeTag("draft 2", from: copy)
                await eventually { harness.tags(copy) == ["Beta"] }
                #expect(try harness.indexOnDisk().copies.first { $0.number == copy }?.tags == ["Beta"])
                #expect(try Fingerprint(file) == before, "the filed copy is untouched")

                try press(.escape, in: harness.window)
                await eventually { harness.cabinet.tagging == nil }
                #expect(
                    harness.modes.mode == .fileCabinet, "Esc in the field closes the field, not the sheet")
                try press(.escape, in: harness.window)
                await eventually { harness.modes.mode == .page }
            }
        }

        /// The window's own From field narrows the cards; a tag chip (its action, `filter.toggle`)
        /// narrows them further. When the last copy with the chosen tag loses it, through a card's ×,
        /// the tag stops filtering rather than filter with no chip showing, and the last click is
        /// forgotten, since the cards changed under the pointer (ADR 0043 §5).
        @Test func theDateFieldsAndTagChipsFilterTheCards() async throws {
            try await withCabinet { harness, actions, _ in
                @MainActor func shown() -> [Int] {
                    FileCabinet.cards(of: harness.book.archive, harness.cabinet.filter).map(\.number.value)
                }
                let pickers = subviewTree(of: harness.window.contentView).compactMap { $0 as? NSDatePicker }
                try #require(pickers.count == 2, "precondition: From and to")
                #expect(pickers.allSatisfy { $0.datePickerStyle == .textField }, "the owner's plain fields")
                let from = try #require(
                    pickers.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
                from.dateValue = Self.day(9, 1).noon(in: .current)
                from.sendAction(from.action, to: from.target)
                await eventually { harness.cabinet.filter.from == Self.day(9, 1) }
                #expect(harness.cabinet.filter.from == Self.day(9, 1))
                #expect(shown() == [2, 3])

                harness.cabinet.filter.toggle("draft 3")
                #expect(shown() == [2])
                let second = try #require(FiledCopyNumber(2))
                actions.click(.single, on: second)
                try #require(harness.cabinet.clicks.last == second, "precondition: the click is kept")

                actions.removeTag("draft 3", from: second)
                await eventually { harness.cabinet.filter.tags.isEmpty }
                #expect(harness.cabinet.filter.tags.isEmpty, "no chosen tag without its chip")
                #expect(shown() == [2, 3])
                #expect(harness.cabinet.clicks.last == nil, "a change to a card's tags forgets the click")
            }
        }

        @Test func aReadOnlyBooksCardsOfferNoTagEditing() async throws {
            try await withCabinet(lock: .heldElsewhere) { harness, actions, _ in
                try #require(!harness.book.archive.copies.isEmpty, "precondition: the cabinet lists copies")
                #expect(!harness.book.accepts(.archive))
                actions.startTagging(try #require(FiledCopyNumber(1)))
                #expect(harness.cabinet.tagging == nil)
                #expect(harness.tagFields.isEmpty, "no + tag field")
            }
        }

        @Test func aBookWithNoCopiesSaysSo() async throws {
            try await withCabinet(records: []) { harness, _, _ in
                #expect(harness.book.archive.copies.isEmpty)
                #expect(harness.searchField == nil, "no filters to show")
            }
        }
    }
}

/// What a test's `open` saw.
@MainActor
final class OpenedCopies {
    var numbers: [FiledCopyNumber] = []
}

/// What can tell a filed copy was changed.
struct Fingerprint: Equatable {
    let contents: Data
    let modified: Date?
    let locked: Bool

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        contents = try Data(contentsOf: url)
        modified = attributes[.modificationDate] as? Date
        locked = attributes[.immutable] as? Bool == true
    }
}

/// The window over a book with `records` filed in order (read-only with `.heldElsewhere`), the
/// File Cabinet open, and actions made from the window's own book and model, whose `open` records
/// what it's asked to open.
@MainActor
func withCabinet(
    records: [FilingRecord] = OneAtATime.FileCabinetSheetTests.records, lock: TestBookLock = .ours,
    _ body: (PageHarness, FileCabinetActions, OpenedCopies) async throws -> Void
) async throws {
    let cabinet = FileCabinetModel()
    try await withPage([ferry], lock: lock, cabinet: cabinet, filed: records) { harness in
        try #require(
            harness.book.archive.copies.count == records.count, "precondition: the copies are listed")
        harness.modes.mode = .fileCabinet
        await eventually { harness.sheetShows }
        try #require(harness.sheetShows, "precondition: the sheet shows")
        let opened = OpenedCopies()
        let actions = FileCabinetActions(
            book: harness.book, store: harness.store, model: cabinet, open: { opened.numbers.append($0) })
        try await body(harness, actions, opened)
    }
}

extension PageHarness {
    var searchField: NSTextField? {
        subviewTree(of: window.contentView).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == FileCabinetWording.searchPlaceholder
        }
    }

    /// The sheet is up: its focus holder is in the window.
    var sheetShows: Bool {
        subviewTree(of: window.contentView).contains { ($0 as? UndoFocusView)?.role == .sheet }
    }

    var tagFields: [AdmittingTextField] {
        subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }
            .filter { $0.placeholderString == TagWording.addPlaceholder }
    }

    func tags(_ copy: FiledCopyNumber) -> [String] {
        book.archive.copies.first { $0.number == copy }?.tags ?? []
    }

    func indexOnDisk() throws -> ArchiveIndex {
        ArchiveIndexFormat.parse(
            try Data(contentsOf: PackageLayout(root: url).archiveIndex),
            filed: { _ in CalendarDay(.now, in: .current) }
        ).index
    }

    /// A card's + tag field, once it has taken the focus as it opens.
    func cabinetTagField() async throws -> AdmittingTextField {
        @MainActor func field() -> AdmittingTextField? {
            subviewTree(of: window.contentView).compactMap { $0 as? AdmittingTextField }.first {
                $0.placeholderString == TagWording.addPlaceholder && $0.currentEditor() != nil
            }
        }
        await eventually { field() != nil }
        return try #require(field(), "precondition: the card's + tag field has the focus")
    }
}
