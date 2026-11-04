import AppKit
import SceneItCore
import Synchronization
import Testing

@testable import SceneIt

/// What the engine was asked, and which searches were cancelled.
nonisolated final class SearchRecorder: Sendable {
    private struct State {
        var indexed: [[SearchUnit]] = []
        var searched: [SearchQuery] = []
        var cancelled: [SearchQuery] = []
    }

    private let state = Mutex(State())
    /// A search for this text reports what it finds but never completes, until it's cancelled.
    let held: String?

    init(holding held: String? = nil) {
        self.held = held
    }

    var indexed: [[SearchUnit]] { state.withLock { $0.indexed } }
    var searched: [SearchQuery] { state.withLock { $0.searched } }
    var cancelled: [SearchQuery] { state.withLock { $0.cancelled } }

    func index(_ units: [SearchUnit]) -> any SearchIndex {
        state.withLock { $0.indexed.append(units) }
        // A held search reports after every unit, so it has something to show before it's held.
        let engine = KeywordSearch(units: units, updateInterval: held == nil ? .milliseconds(50) : .zero)
        return RecordingIndex(engine: engine, recorder: self)
    }

    fileprivate func searching(_ query: SearchQuery) {
        state.withLock { $0.searched.append(query) }
    }

    fileprivate func cancelled(_ query: SearchQuery) {
        state.withLock { $0.cancelled.append(query) }
    }
}

/// The real engine, reporting through a stream that records the query, and holds back the
/// held query's last update until the search is cancelled.
private nonisolated struct RecordingIndex: SearchIndex {
    let engine: KeywordSearch
    let recorder: SearchRecorder

    func search(_ query: SearchQuery) -> AsyncStream<SearchUpdate> {
        recorder.searching(query)
        let updates = engine.search(query)
        let holds = recorder.held.map { SearchQuery($0, options: query.options) == query } ?? false
        let recorder = recorder
        return AsyncStream { continuation in
            let task = Task {
                for await update in updates {
                    if holds, update.progress == .complete {
                        while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
                        recorder.cancelled(query)
                        break
                    }
                    continuation.yield(update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private func paragraphs(_ texts: [String]) -> [Paragraph] {
    texts.map { [Run($0)] }
}

private func scene(_ title: String, body: [String], notes: [String] = [], tags: [String] = []) -> BookScene {
    var ids = IDGenerator.system
    return BookScene(
        id: ids.sceneID(), modified: Timestamp(.now, in: .current), title: SceneTitle(title), tags: tags,
        body: paragraphs(body), notes: paragraphs(notes))
}

extension SearchSheetModel {
    /// What the sheet lists once the current query's search is complete.
    fileprivate var completeListing: SearchListing? {
        guard case .results(let listing, .current) = state, listing.progress == .complete else { return nil }
        return listing
    }

    fileprivate func completed() async throws -> SearchListing {
        await eventually(within: .seconds(60)) { completeListing != nil }
        return try #require(completeListing)
    }
}

/// Opens the Search sheet as the rail does, and waits until it's up: it has taken the focus
/// from the title and the page, as it does before the writer can open a result.
@MainActor
private func showSheet(_ page: PageHarness) async throws {
    page.modes.mode = .search
    await eventually(within: .seconds(60)) {
        page.title.currentEditor() == nil && page.window.firstResponder !== page.page
            && subviewTree(of: page.window.contentView).contains {
                ($0 as? UndoFocusView)?.role == .sheet
            }
    }
}

@Suite(.timeLimit(.minutes(5)))
struct SearchSheetTests {
    @Test func theCheckboxesAreTheQuerysOptions() async throws {
        let scenes = [scene("Bears", body: ["A Bear crossed.", "Two bears."], tags: ["bear"])]
        try await withPage(scenes) { page in
            let recorder = SearchRecorder()
            let model = SearchSheetModel(book: page.book) { recorder.index($0) }
            model.text = "bear"
            let listed = try await model.completed()
            #expect(listed.hitCount == 3, "the title and both paragraphs, not the tags")
            for (checkbox, expected) in [
                (SearchCheckbox.searchTags, 4), (.matchCase, 1), (.wholeWord, 1),
            ] {
                model.set(checkbox, .on)
                #expect(model.isOn(checkbox))
                #expect(model.query.options == checkbox.option)
                let listed = try await model.completed()
                #expect(recorder.searched.last == SearchQuery("bear", options: checkbox.option))
                #expect(listed.hitCount == expected, "\(checkbox)")
                model.set(checkbox, .off)
                #expect(!model.isOn(checkbox))
            }
            for checkbox in SearchCheckbox.allCases { model.set(checkbox, .on) }
            #expect(model.query == SearchQuery("bear", options: [.searchTags, .matchCase, .wholeWord]))
            _ = try await model.completed()
            #expect(recorder.searched.last == model.query)
        }
    }

    @Test func emptyAndWordlessQueriesDontSearch() async throws {
        try await withPage([scene("One", body: ["A bear."])]) { page in
            let recorder = SearchRecorder()
            let model = SearchSheetModel(book: page.book) { recorder.index($0) }
            #expect(model.state == .prompt(.wholeBook))
            model.text = "  "
            #expect(model.state == .prompt(.wholeBook))
            model.text = "-- ..."
            #expect(model.state == .noWords)
            model.scope = .thisScene
            #expect(model.state == .noWords)
            model.text = ""
            #expect(model.state == .prompt(.thisScene))
            #expect(recorder.searched.isEmpty)
        }
    }

    /// The sheet narrows the units, so This scene has near matches of its own while another
    /// scene has an exact match.
    @Test func thisSceneSearchesOnlyTheOpenScenesUnits() async throws {
        let claw = scene("Claw", body: ["A bear claw."])
        let paw = scene("Paw", body: ["A bear paw."], notes: ["The bear again."])
        try await withPage([claw, paw]) { page in
            page.book.select(paw.id)
            let recorder = SearchRecorder()
            let model = SearchSheetModel(book: page.book) { recorder.index($0) }
            model.text = "bear claw"
            let book = try await model.completed()
            #expect(book.quality == .exact)
            #expect(book.scenes.map(\.scene) == [claw.id])

            model.scope = .thisScene
            let open = try await model.completed()
            #expect(recorder.indexed.last?.allSatisfy { $0.scene == paw.id } == true)
            #expect(recorder.indexed.last?.isEmpty == false, "precondition: the open scene has units")
            #expect(open.quality == .near)
            #expect(open.scenes.map(\.scene) == [paw.id])
            let body = try #require(open.scenes.first?.hits.first { $0.unit.field == .body(paragraph: 0) })
            let differs = body.highlights.filter { $0.kind == .differs }
            #expect(differs.map(\.range) == [7..<10], "paw")

            page.book.select(nil)
            model.refresh()
            #expect(model.state == .noSceneOpen)
        }
    }

    @Test func nearMatchesListTheBestScenesUntilShowAll() async throws {
        let count = NearMatchLimit.bestCount + 10
        let scenes = (1...count).map { scene("Scene \($0)", body: ["A bear here."]) }
        try await withPage(scenes) { page in
            let model = SearchSheetModel(book: page.book)
            model.text = "bear claw"
            let best = try await model.completed()
            #expect(best.quality == .near, "precondition: no unit has both words")
            #expect(best.sceneCount == count)
            #expect(best.scenes.count == NearMatchLimit.bestCount)
            #expect(best.hiddenSceneCount == 10)

            model.showAllNearMatches()
            let all = try #require(model.completeListing)
            #expect(all.scenes.count == count)
            #expect(all.hiddenSceneCount == 0)

            model.text = "bear claws"
            let listed = try await model.completed()
            #expect(listed.scenes.count == NearMatchLimit.bestCount, "a new query caps again")

            model.text = "bear"
            let exact = try await model.completed()
            #expect(exact.quality == .exact)
            #expect(exact.scenes.count == count, "exact matches aren't capped")
        }
    }

    @Test func aNewQueryCancelsTheSearchInProgress() async throws {
        let scenes = (1...3).map { scene("Scene \($0)", body: ["The letter.", "The ferry."]) }
        try await withPage(scenes) { page in
            let recorder = SearchRecorder(holding: "letter")
            let model = SearchSheetModel(book: page.book) { recorder.index($0) }
            model.text = "letter"
            await eventually(within: .seconds(60)) {
                if case .results(_, .current) = model.state { true } else { false }
            }
            guard case .results(let partial, .current) = model.state else { return }
            #expect(partial.progress != .complete, "precondition: the held search is still in progress")
            #expect(recorder.cancelled.isEmpty)

            model.text = "ferry"
            let ferry = try await model.completed()
            await eventually(within: .seconds(60)) { recorder.cancelled == [SearchQuery("letter")] }
            #expect(ferry.hitCount == 3)
            #expect(model.reported?.query == SearchQuery("ferry"))
            await model.settle()
            #expect(
                model.reported?.query == SearchQuery("ferry"), "the cancelled search reported nothing more")
        }
    }

    @Test func expandingAScenesMoreLastsUntilTheNextQuery() async throws {
        try await withPage([scene("One", body: ["A bear.", "A bear.", "A bear."])]) { page in
            let model = SearchSheetModel(book: page.book)
            model.text = "bear"
            let hits = try #require(try await model.completed().scenes.first)
            #expect(hits.moreCount == 2)
            model.toggleExpanded(hits)
            #expect(model.isExpanded(hits))
            model.toggleExpanded(hits)
            #expect(!model.isExpanded(hits))
            model.toggleExpanded(hits)
            model.text = "bears"
            #expect(!model.isExpanded(hits))
        }
    }

    // MARK: Opening a result, through the window

    @Test func openingAResultOpensItsSceneAndSelectsTheMatch() async throws {
        let first = scene("The lighthouse", body: ["Dawn came."])
        let second = scene(
            "Arrival", body: ["Dawn came.", "He found the letter under the bench."],
            notes: ["Check the handwriting."])
        try await withPage([first, second]) { page in
            #expect(page.book.openScene == first.id, "precondition: the first scene is open")
            let model = page.search

            try await showSheet(page)
            model.text = "bench"
            let body = try #require(try await model.completed().scenes.first?.best)
            model.open(body)
            #expect(page.modes.mode == .page)
            #expect(page.book.openScene == second.id)
            let bench = NSRange(location: 41, length: 5)
            await eventually(within: .seconds(60)) {
                page.page.selectedRange() == bench && page.window.firstResponder === page.page
            }
            #expect(
                (page.storage.string as NSString).range(of: "bench") == bench,
                "precondition: the match is in the second paragraph, which the page shows")

            try await showSheet(page)
            model.text = "lighthouse"
            let title = try #require(try await model.completed().scenes.first?.best)
            model.open(title)
            #expect(page.book.openScene == first.id)
            await eventually(within: .seconds(60)) {
                page.title.currentEditor()?.selectedRange == NSRange(location: 4, length: 10)
                    && page.window.firstResponder === page.title.currentEditor()
            }

            try await showSheet(page)
            model.text = "handwriting"
            let notes = try #require(try await model.completed().scenes.first?.best)
            model.open(notes)
            #expect(page.book.openScene == second.id)
            #expect(page.preferences.rightPanelTab == .notes)
            await eventually(within: .seconds(60)) {
                guard let focused = page.window.firstResponder as? SceneTextView else { return false }
                return !(focused is ManuscriptTextView)
                    && focused.selectedRange() == NSRange(location: 10, length: 11)
            }
            #expect(
                !(page.window.firstResponder is ManuscriptTextView), "the notes have the focus")
        }
    }

    @Test func openingTheSheetSearchesTheBookAsItIsNow() async throws {
        try await withPage([scene("One", body: ["A bear."])]) { page in
            let model = page.search
            model.text = "wolf"
            let listed = try await model.completed()
            #expect(listed.sceneCount == 0)
            let id = try #require(page.book.openScene)
            page.book.replaceBody(of: id, with: paragraphs(["A wolf."]))
            page.modes.mode = .search
            await eventually(within: .seconds(60)) { model.completeListing?.sceneCount == 1 }
        }
    }
}
