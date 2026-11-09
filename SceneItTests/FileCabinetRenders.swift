import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

/// The File Cabinet sheet (#33) in the window at 1× and 2×, beside mockup 12: the look the owner
/// picked (`final-cabinet-*`) in each state. In a
/// `cabinet/` subfolder. The day is mockup 12's, Nov 1, 2026, so the ages read as its do.
extension WindowRenders {
    static let fileCabinetMockup = "12-file-cabinet.png"

    static func cabinetDay(_ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: 2026, month: month, day: day)!
    }

    /// Mockup 12's five copies, oldest first, each of the story as it was then.
    static func mockupCopies() -> [(FilingRecord, scenes: Int)] {
        [
            (
                FilingRecord(
                    filed: cabinetDay(3, 16), tags: ["draft 1", "complete"], note: "First complete draft."),
                16
            ),
            (
                FilingRecord(
                    filed: cabinetDay(7, 14), tags: ["draft 2"], note: "Before cutting the brother subplot."),
                20
            ),
            (
                FilingRecord(
                    filed: cabinetDay(9, 17), tags: ["contest", "first 3 chapters"],
                    note: "Version submitted to the regional fiction contest."), 21
            ),
            (
                FilingRecord(
                    filed: cabinetDay(10, 13), tags: ["draft 3"],
                    note: "After the big restructure: Fog moved before Debts."), 24
            ),
            (
                FilingRecord(
                    filed: cabinetDay(10, 30), tags: ["beta readers", "draft 3"],
                    note: "Sent to the four beta readers. Ending still soft."), 24
            ),
        ]
    }

    static func mockupTicker() -> MinuteTicker {
        let now = cabinetDay(11, 1).noon(in: .current)
        return MinuteTicker(clock: ContinuousClock(), period: .days(1), wallTime: { now })
    }

    @Test func fileCabinet() async throws {
        let output = try #require(renderFolder).appending(path: "cabinet", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        @MainActor func state(
            _ book: AppOpenBook, _ store: AppBookStore, _ preferences: AppPreferences,
            _ model: FileCabinetModel,
            _ name: String, _ caption: String, _ prepare: @escaping (NSWindow) async throws -> Void = { _ in }
        ) async throws {
            let window = BookWindow(
                book: book, store: store, preferences: preferences,
                formatting: EditorFormatting(preferences: preferences), mode: .constant(.fileCabinet),
                cabinet: model)
            let renders = try await Self.render(window, in: KeyWindow.self, preparing: prepare)
            try Self.write(renders, name: name, caption: caption, to: output, beside: Self.fileCabinetMockup)
        }

        try await withFiledSample(Self.mockupCopies()) { store, book, preferences in
            let model = FileCabinetModel(ticker: Self.mockupTicker())
            try await state(
                book, store, preferences, model, "final-cabinet", "File Cabinet: five filed copies")
            let selected = try #require(FiledCopyNumber(4))
            try await state(
                book, store, preferences, model, "final-cabinet-selected", "A card selected (one click)"
            ) { _ in
                model.keyFocus.takeFocus()
                model.selected = selected
            }
            model.selected = nil
            try await state(
                book, store, preferences, model, "final-cabinet-tagging", "+ tag clicked on the Oct 13 card"
            ) { window in
                model.tagging = selected
                await eventually { Self.newTagField(in: window)?.currentEditor() != nil }
                let field = try #require(Self.newTagField(in: window), "precondition: the card's field")
                let editor = try #require(
                    field.currentEditor() as? NSTextView, "precondition: it took the focus")
                editor.insertText("agent", replacementRange: editor.selectedRange())
            }
            model.tagging = nil
            model.filter = CabinetFilter(from: Self.cabinetDay(9, 1))
            model.filter.toggle("draft 3")
            try await state(
                book, store, preferences, model, "final-cabinet-filters",
                "Filters: from Sep 1, 2026, and the tag draft 3")
            model.filter = CabinetFilter(words: "draft")
            try await state(
                book, store, preferences, model, "final-cabinet-search", "Search: draft (tags and notes)")
            model.filter = CabinetFilter(words: "lighthouse")
            try await state(
                book, store, preferences, model, "final-cabinet-no-matches", "Search with no matches")
            model.filter = CabinetFilter()
        }
        try await withFiledSample([]) { store, book, preferences in
            try await state(
                book, store, preferences, FileCabinetModel(ticker: Self.mockupTicker()),
                "final-cabinet-empty",
                "No filed copies yet")
        }
        try await withFiledSample(Self.mockupCopies(), lock: .heldElsewhere) { store, book, preferences in
            try #require(!book.accepts(.archive), "precondition: the cabinet can't be changed")
            try await state(
                book, store, preferences, FileCabinetModel(ticker: Self.mockupTicker()),
                "final-cabinet-read-only",
                "A read-only book: tags without × or + tag")
        }
    }

    /// The sample book with `copies` filed, each of its first `scenes` scenes, then opened through a
    /// test-host store; with `.heldElsewhere`, opened read-only.
    func withFiledSample(
        _ copies: [(FilingRecord, scenes: Int)], lock: TestBookLock = .ours,
        _ body: (AppBookStore, AppOpenBook, AppPreferences) async throws -> Void
    ) async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            #expect(await store.closeBook() == .left)
            let sample = Self.sampleBook()
            var holder = try BookPackage.open(at: url).editable
            try #require(holder != nil, "precondition: the package opens for filing")
            for (record, count) in copies {
                var then = sample
                then.scenes = Array(sample.scenes.prefix(count))
                _ = try holder?.package.fileCopy(of: then, as: record)
            }
            _ = try holder?.package.save(sample)
            switch lock {
            case .ours:
                holder = nil
                #expect(await store.open(url) == .opened)
            case .heldElsewhere:
                #expect(await store.open(url) == .openedReadOnly(.openElsewhere))
            }
            let book = try #require(store.current)
            try await body(store, book, books.preferences)
            #expect(await store.closeBook() == .left)
            withExtendedLifetime(holder) {}
        }
    }
}
