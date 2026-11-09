import AppKit
import SceneItCore
import SceneItTestSupport
import SwiftUI
import Testing

@testable import SceneIt

private let ferry = scene("The ferry", [[Run("The ferry left at dawn. Mara watched.")]])
private let letter = scene("The letter", [[Run("Dawn came. He read the letter twice.")]])

/// The Search sheet's File Cabinet scope (#34, PLAN §9.1) in the real window, over a book with
/// three filed copies of its two scenes: every copy searched and grouped newest first, the copy
/// picker and the date range, the copies' own tags, a copy that can't be read, and a result
/// opening its copy read-only at its scene. The copies' files are never written.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct CabinetSearchSheetTests {
    static func day(_ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: 2026, month: month, day: day)!
    }

    static let records = [
        FilingRecord(filed: day(3, 16), tags: ["draft 1"]),
        FilingRecord(filed: day(9, 17), tags: ["contest"]),
        FilingRecord(filed: day(10, 30), tags: ["beta readers", "draft 3"]),
    ]

    static func filed(_ numbers: [Int]) -> [SearchVersion] {
        numbers.map { .filed(FiledCopyNumber($0)!) }
    }

    /// The window over the book, its copies filed, the sheet up in the File Cabinet scope; the
    /// book's own letter scene rewritten since, so its text is no longer the copies'.
    private func withCabinetSearch(_ body: (PageHarness, [Fingerprint]) async throws -> Void) async throws {
        try await withPage([ferry, letter], filed: Self.records) { page in
            try #require(page.book.archive.copies.count == 3, "precondition: three copies")
            page.book.replaceBody(of: letter.id, with: [[Run("Rewritten since.")]])
            let layout = PackageLayout(root: page.url)
            let files = try page.book.archive.copies.map { try Fingerprint(layout.filedCopy($0.number)) }
            try await showSheet(page)
            page.search.scope = .fileCabinet
            try await body(page, files)
            #expect(
                try page.book.archive.copies.map { try Fingerprint(layout.filedCopy($0.number)) } == files,
                "the copies' bytes, times and locks")
        }
    }

    @Test func everyCopyIsSearchedAndGroupedNewestFirst() async throws {
        try await withCabinetSearch { page, _ in
            let model = page.search
            #expect(model.state == .prompt(.fileCabinet))
            model.text = "letter"
            let listing = try await model.completed()
            let versions = model.versions(listing)
            #expect(versions.map(\.version) == Self.filed([3, 2, 1]))
            #expect(versions.allSatisfy { $0.scenes.map(\.scene) == [letter.id] })
            let texts = versions.flatMap(\.scenes).flatMap(\.hits).filter {
                $0.unit.field == .body(paragraph: 0)
            }
            .map(\.unit.text)
            #expect(
                texts == Array(repeating: "Dawn came. He read the letter twice.", count: 3),
                "the copies' text")
            #expect(
                SearchWording.cabinetSummary(listing.cabinetCounts)
                    == "6 matches in 3 scenes across 3 filed copies", "the title and the text in each")
            #expect(model.unreadable.isEmpty)
            #expect(model.copy(versions[0].version)?.tags == ["beta readers", "draft 3"])

            model.scope = .wholeBook
            let working = try await model.completed()
            #expect(working.scenes.map(\.version) == [.working])
            #expect(working.hitCount == 1, "the book's own letter scene has only its title left")
        }
    }

    /// The picker through its selection (a SwiftUI menu, which puts no AppKit control in the window
    /// offscreen); the range through the window's own "filed from" field.
    @Test func thePickerAndTheDateRangeNarrowTheCopies() async throws {
        try await withCabinetSearch { page, _ in
            let model = page.search
            let copies = page.book.archive.copies
            @MainActor func pickerTitles() -> [String] {
                let pickable = model.cabinet.pickable(in: page.book.archive)
                return [SearchWording.allCopies(pickable.count, model.cabinet.dates)]
                    + pickable.map(SearchWording.copy)
            }
            let newestFirst = [copies[2], copies[1], copies[0]].map(SearchWording.copy)
            #expect(pickerTitles() == ["All filed copies (3)"] + newestFirst)
            #expect(SearchWording.copy(copies[2]) == "Oct 30, 2026 \u{00B7} beta readers, draft 3")
            await eventually { Self.datePickers(page).count == 2 }
            let dates = Self.datePickers(page)
            try #require(dates.count == 2, "precondition: filed from and to")
            #expect(dates.allSatisfy { $0.datePickerStyle == .textField }, "the File Cabinet's own fields")

            model.text = "ferry"
            model.cabinet.copy = FiledCopyNumber(2)
            let picked = try await model.completed()
            #expect(model.versions(picked).map(\.version) == Self.filed([2]))

            let from = try #require(dates.first)
            from.dateValue = Self.day(10, 1).noon(in: .current)
            from.sendAction(from.action, to: from.target)
            await eventually { model.cabinet.dates.from == Self.day(10, 1) }
            #expect(model.cabinet.dates == FiledDates(from: Self.day(10, 1)))
            #expect(model.cabinet.copy == nil, "the picked copy left the range, so it's forgotten")
            let inRange = try await model.completed()
            #expect(model.versions(inRange).map(\.version) == Self.filed([3]))
            #expect(pickerTitles() == ["All filed copies in range (1)", SearchWording.copy(copies[2])])

            model.cabinet.dates = FiledDates(to: Self.day(1, 1))
            #expect(model.state == .noCopiesInRange)
        }
    }

    @Test func aCopysOwnTagsAreSearchedWithSearchTags() async throws {
        try await withCabinetSearch { page, _ in
            let model = page.search
            model.text = "draft"
            #expect(try await model.completed().sceneCount == 0, "no copy's text says draft")
            model.set(.searchTags, .on)
            let listing = try await model.completed()
            #expect(listing.scenes.allSatisfy { $0.scene == nil })
            #expect(Set(listing.scenes.map(\.version)) == Set(Self.filed([1, 3])))
            #expect(SearchWording.cabinetSummary(listing.cabinetCounts) == "Tags match on 2 copies")
        }
    }

    /// Trust: a copy whose file has gone is skipped with a note, and the others are still searched.
    /// The file is moved aside, then back as it was.
    @Test func aCopyThatCantBeReadIsSkippedWithANote() async throws {
        try await withCabinetSearch { page, _ in
            let manager = FileManager.default
            let gone = PackageLayout(root: page.url).filedCopy(FiledCopyNumber(2)!)
            let aside = page.url.deletingLastPathComponent().appending(path: "aside.md")
            try manager.setAttributes([.immutable: false], ofItemAtPath: gone.path(percentEncoded: false))
            try manager.moveItem(at: gone, to: aside)
            defer {
                try? manager.moveItem(at: aside, to: gone)
                try? manager.setAttributes([.immutable: true], ofItemAtPath: gone.path(percentEncoded: false))
            }
            let model = page.search
            model.text = "ferry"
            let listing = try await model.completed()
            #expect(model.unreadable == [FiledCopyNumber(2)!])
            #expect(model.versions(listing).map(\.version) == Self.filed([3, 1]))
            #expect(SearchWording.unreadable(1) == "1 filed copy couldn't be read, so it wasn't searched.")
        }
    }

    /// Opening a result in a copy (the row's click) opens that copy read-only over the book, at the
    /// result's scene, for the copy's window to select the match.
    @Test func aResultOpensItsCopyReadOnlyAtItsScene() async throws {
        try await withCabinetSearch { page, _ in
            let model = page.search
            page.book.select(ferry.id)
            model.text = "twice"
            let hit = try #require(model.versions(try await model.completed()).first?.scenes.first?.best)
            #expect(hit.unit.version == .filed(FiledCopyNumber(3)!))
            model.open(hit)
            await eventually { page.store.shown !== page.book }
            let copy = try #require(page.store.shown)
            #expect(copy.document.kind == .filedCopy)
            #expect(copy.searchVersion == hit.unit.version)
            #expect(copy.openScene == letter.id)
            #expect(copy.searchArrival == hit)
            #expect(page.book.openScene == ferry.id, "the book keeps its scene for Close")
            page.store.closeFiledCopy()
        }
    }

    /// The window's date fields, leftmost first.
    private static func datePickers(_ page: PageHarness) -> [NSDatePicker] {
        subviewTree(of: page.window.contentView).compactMap { $0 as? NSDatePicker }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// The copy's own window, as the app shows it, selects the result's match on its page.
    @Test func theCopysWindowSelectsTheMatch() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let store = books.store
            let url = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            #expect(await store.create(at: url) == .created)
            let book = try #require(store.current)
            let first = try #require(book.addScene(after: nil))
            book.replaceBody(of: first, with: [[Run("The ferry left at dawn.")]])
            let second = try #require(book.addScene(after: first))
            book.replaceBody(of: second, with: [[Run("Dawn came."), Run(" He read the letter twice.")]])
            guard case .filed = await store.fileACopy(of: book, as: Self.records[0]) else {
                Issue.record("precondition: a copy is filed")
                return
            }
            book.replaceBody(of: second, with: [[Run("Rewritten since.")]])
            book.select(first)

            let model = SearchSheetModel(book: book)
            model.scope = .fileCabinet
            model.text = "letter"
            let hit = try #require(try await model.completed().scenes.first?.best)

            let size = WindowMetrics.defaultSize
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: MainWindow(books: books))
            window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
            window.orderFront(nil)
            defer { window.close() }
            @MainActor func page() -> ManuscriptTextView? {
                subviewTree(of: window.contentView).compactMap { $0 as? ManuscriptTextView }.first
            }
            await eventually { page()?.string == "The ferry left at dawn." }

            #expect(await store.openFiledCopy(.first, of: book, showing: hit) == .opened)
            let text = "Dawn came. He read the letter twice."
            let match = (text as NSString).range(of: "letter")
            await eventually {
                page()?.string == text && page()?.selectedRange() == match && window.firstResponder === page()
            }
            #expect(page()?.string == text, "the copy, at the result's scene")
            #expect(page()?.selectedRange() == match)
            #expect(store.shown?.searchArrival == nil, "taken by the window")
            store.closeFiledCopy()
            #expect(await store.closeBook() == .left)
        }
    }
}
