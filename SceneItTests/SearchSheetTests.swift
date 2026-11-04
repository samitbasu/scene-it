import AppKit
import SceneItCore
import SceneItTestSupport
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

/// Holds back indexing while it's shut, so a test can look at the sheet before the book is
/// searched again.
nonisolated final class IndexGate: Sendable {
    private struct State {
        var isOpen = true
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func shut() {
        state.withLock { $0.isOpen = false }
    }

    func open() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    /// Keyword search, built once the gate lets it through.
    var indexing: SearchSheetModel.Indexing {
        { units in
            await self.pass()
            return KeywordSearch(units: units)
        }
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            let passes = state.withLock { state in
                if !state.isOpen { state.waiting.append(continuation) }
                return state.isOpen
            }
            if passes { continuation.resume() }
        }
    }
}

/// An index whose search for `late` reports its first update, then, once it's cancelled, one
/// more, as a search that ignored cancellation for a moment would: the sheet must not show it.
private nonisolated struct LateIndex: SearchIndex {
    let engine: KeywordSearch
    let late: SearchQuery
    let recorder: LateRecorder

    func search(_ query: SearchQuery) -> LateUpdates {
        LateUpdates(engine: engine, query: query, isLate: query == late, recorder: recorder)
    }
}

nonisolated final class LateRecorder: Sendable {
    private let finished = Mutex(false)
    /// The late update waits for this as well as for the cancellation, so a test can deliver
    /// it after the next search has reported.
    let release: IndexGate = {
        let gate = IndexGate()
        gate.shut()
        return gate
    }()

    /// Whether the late search's iterator is gone: its task has done with every update.
    var lateSearchFinished: Bool { finished.withLock { $0 } }

    fileprivate func finish() {
        finished.withLock { $0 = true }
    }
}

private nonisolated struct LateUpdates: AsyncSequence, Sendable {
    let engine: KeywordSearch
    let query: SearchQuery
    let isLate: Bool
    let recorder: LateRecorder

    func makeAsyncIterator() -> Iterator {
        Iterator(engine: engine, query: query, isLate: isLate, token: isLate ? Token(recorder) : nil)
    }

    /// Tells the recorder when the iterator is gone.
    nonisolated final class Token: Sendable {
        let recorder: LateRecorder
        init(_ recorder: LateRecorder) { self.recorder = recorder }
        deinit { recorder.finish() }
    }

    nonisolated struct Iterator: AsyncIteratorProtocol {
        let engine: KeywordSearch
        let query: SearchQuery
        let isLate: Bool
        let token: Token?
        var pending: [SearchUpdate]?

        init(engine: KeywordSearch, query: SearchQuery, isLate: Bool, token: Token?) {
            self.engine = engine
            self.query = query
            self.isLate = isLate
            self.token = token
        }

        mutating func next() async -> SearchUpdate? {
            if pending == nil {
                var all: [SearchUpdate] = []
                for await update in engine.search(query) { all.append(update) }
                pending = all
            }
            guard var updates = pending, !updates.isEmpty else { return nil }
            if isLate, updates.count == 1 {
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
                await token?.recorder.release.pass()
            }
            let update = updates.removeFirst()
            pending = isLate && updates.count > 1 ? [updates.last!] : updates
            return update
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
    /// What the sheet lists for the current query, complete or not.
    fileprivate var currentListing: SearchListing? {
        if case .results(let listing, .current) = state { listing } else { nil }
    }

    /// What the sheet lists once the current query's search is complete.
    fileprivate var completeListing: SearchListing? {
        currentListing.flatMap { $0.progress == .complete ? $0 : nil }
    }

    fileprivate func completed() async throws -> SearchListing {
        await settle()
        return try #require(completeListing)
    }
}

/// Opens the Search sheet as the rail does, and waits until it's up: it has taken the focus
/// from the title and the page, as it does before the writer can open a result.
@MainActor
private func showSheet(_ page: PageHarness) async throws {
    page.modes.mode = .search
    await eventually {
        page.title.currentEditor() == nil && page.window.firstResponder !== page.page
            && subviewTree(of: page.window.contentView).contains {
                ($0 as? UndoFocusView)?.role == .sheet
            }
    }
}

/// Closes the Search sheet as × does, and waits until it's gone.
@MainActor
private func hideSheet(_ page: PageHarness) async {
    page.modes.mode = .page
    await eventually {
        !subviewTree(of: page.window.contentView).contains { ($0 as? UndoFocusView)?.role == .sheet }
    }
}

@Suite(.timeLimit(.minutes(2)))
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
            await eventually { model.currentListing != nil }
            let partial = try #require(model.currentListing)
            #expect(partial.progress != .complete, "precondition: the held search is still in progress")
            #expect(recorder.cancelled.isEmpty)

            model.text = "ferry"
            let ferry = try await model.completed()
            await eventually { recorder.cancelled == [SearchQuery("letter")] }
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

    /// A search that reports once more after it's cancelled can't replace the next search's
    /// results: the model checks for cancellation before it shows an update.
    @Test func anUpdateFromACancelledSearchIsNeverShown() async throws {
        let scenes = (1...3).map { scene("Scene \($0)", body: ["The letter.", "The ferry."]) }
        try await withPage(scenes) { page in
            let late = LateRecorder()
            let model = SearchSheetModel(book: page.book) { units in
                LateIndex(
                    engine: KeywordSearch(units: units, updateInterval: .zero), late: SearchQuery("letter"),
                    recorder: late)
            }
            model.text = "letter"
            await eventually { model.currentListing != nil }
            #expect(
                model.currentListing?.progress != .complete, "precondition: the late search is in progress")

            model.text = "ferry"
            let ferry = try await model.completed()
            #expect(ferry.hitCount == 3)
            #expect(!late.lateSearchFinished, "precondition: the late update is still to come")
            late.release.open()
            await eventually { late.lateSearchFinished }
            #expect(model.reported?.query == SearchQuery("ferry"), "the late update wasn't shown")
            #expect(model.currentListing == ferry)
        }
    }

    @Test func closingTheSheetStopsTheSearchAndLetsGoOfTheIndexes() async throws {
        let scenes = (1...3).map { scene("Scene \($0)", body: ["The letter.", "The ferry."]) }
        let recorder = SearchRecorder(holding: "letter")
        let indexing: SearchSheetModel.Indexing = { recorder.index($0) }
        try await withPage(scenes, searchIndexing: indexing) { page in
            let model = page.search
            try await showSheet(page)
            model.text = "letter"
            await eventually { model.currentListing != nil }
            #expect(recorder.indexed.count == 1)

            await hideSheet(page)
            await eventually { recorder.cancelled == [SearchQuery("letter")] }
            await model.settle()
            #expect(model.reported == nil, "the results went with the sheet")

            try await showSheet(page)
            await eventually { recorder.indexed.count == 2 }
            #expect(recorder.searched.last == SearchQuery("letter"), "reopening searches again, afresh")
        }
    }

    /// What one opening of the sheet found is never shown, as current, by the next, which
    /// searches the book as it is then.
    @Test func reopeningAfterSwitchingScenesShowsOnlyTheNewScene() async throws {
        let first = scene("One", body: ["A bear."])
        let second = scene("Two", body: ["Two bears."])
        let gate = IndexGate()
        try await withPage([first, second], searchIndexing: gate.indexing) { page in
            let model = page.search
            try await showSheet(page)
            model.scope = .thisScene
            model.text = "bear"
            let listed = try await model.completed()
            #expect(listed.scenes.map(\.scene) == [first.id])

            await hideSheet(page)
            page.book.select(second.id)
            gate.shut()
            try await showSheet(page)
            #expect(model.reported == nil, "nothing from the last opening")
            #expect(model.state == .searching)
            gate.open()
            let reopened = try await model.completed()
            #expect(reopened.scenes.map(\.scene) == [second.id])
        }
    }

    @Test func reopeningAfterAnEditShowsTheEditedText() async throws {
        let only = scene("One", body: ["A bear.", "A wolf."])
        let gate = IndexGate()
        try await withPage([only], searchIndexing: gate.indexing) { page in
            let model = page.search
            try await showSheet(page)
            model.text = "bear"
            let listed = try await model.completed()
            #expect(listed.scenes.first?.best.unit.text == "A bear.")

            await hideSheet(page)
            page.book.replaceBody(of: only.id, with: paragraphs(["A wolf.", "The old bear."]))
            gate.shut()
            try await showSheet(page)
            #expect(model.reported == nil, "nothing from the last opening")
            gate.open()
            let edited = try #require(try await model.completed().scenes.first?.best)
            #expect(edited.unit.text == "The old bear.")
            #expect(edited.unit.field == .body(paragraph: 1))
        }
    }

    @Test func openingAHitWhoseTextChangedSelectsNothing() async throws {
        let first = scene("One", body: ["Dawn came."])
        let second = scene("Two", body: ["Dawn came.", "He found the letter under the bench."])
        try await withPage([first, second]) { page in
            let model = page.search
            try await showSheet(page)
            model.text = "bench"
            let hit = try #require(try await model.completed().scenes.first?.best)
            page.book.replaceBody(of: second.id, with: paragraphs(["Dawn came.", "The bench was empty."]))

            model.open(hit)
            #expect(page.book.openScene == second.id, "the scene still opens")
            #expect(page.modes.mode == .page)
            await eventually { page.pageMirrorsModel }
            #expect(page.page.selectedRange().length == 0, "no words are selected")
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
            await eventually {
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
            await eventually {
                page.title.currentEditor()?.selectedRange == NSRange(location: 4, length: 10)
                    && page.window.firstResponder === page.title.currentEditor()
            }

            try await showSheet(page)
            model.text = "handwriting"
            let notes = try #require(try await model.completed().scenes.first?.best)
            model.open(notes)
            #expect(page.book.openScene == second.id)
            #expect(page.preferences.rightPanelTab == .notes)
            // The notes take the focus, with the match selected.
            await eventually {
                guard let focused = page.window.firstResponder as? SceneTextView else { return false }
                return !(focused is ManuscriptTextView)
                    && focused.selectedRange() == NSRange(location: 10, length: 11)
            }
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
            await eventually { model.completeListing?.sceneCount == 1 }
        }
    }

    /// A scene with a comment on "letter", the tag "harbor", and its own words.
    private static func commentedScene() -> BookScene {
        var ids = IDGenerator.system
        let comment = Comment(
            id: ids.commentID(), color: .purple, text: "Check the postmark.",
            created: Timestamp(.now, in: .current))
        return BookScene(
            id: ids.sceneID(), modified: Timestamp(.now, in: .current), title: "Arrival", tags: ["harbor"],
            body: [[Run("He found the "), Run("letter", comments: [comment.id]), Run(" early.")]],
            comments: [comment])
    }

    @Test func openingACommentOrTagHitShowsItsTab() async throws {
        let first = scene("One", body: ["Dawn came."])
        let second = Self.commentedScene()
        try await withPage([first, second]) { page in
            let model = page.search
            try await showSheet(page)
            model.text = "postmark"
            let comment = try #require(try await model.completed().scenes.first?.best)
            #expect(comment.unit.field == .comment(second.comments[0].id), "precondition: a comment hit")
            model.open(comment)
            #expect(page.book.openScene == second.id)
            #expect(page.modes.mode == .page)
            #expect(page.preferences.rightPanelTab == .comments)
            #expect(page.preferences.rightPanel == .open)

            page.book.select(first.id)
            try await showSheet(page)
            model.set(.searchTags, .on)
            model.text = "harbor"
            let tags = try #require(try await model.completed().scenes.first?.best)
            #expect(tags.unit.field == .tags, "precondition: a tag hit")
            model.open(tags)
            #expect(page.book.openScene == second.id)
            #expect(page.preferences.rightPanelTab == .tags)
        }
    }

    @Test func aBoneyardHitIsLabelledBAndOpensTheBoneyardScene() async throws {
        let cut = scene("Cut", body: ["An old lantern."])
        try await withPage([scene("One", body: ["Dawn came."])], boneyard: [cut]) { page in
            let model = page.search
            try await showSheet(page)
            model.text = "lantern"
            let hits = try #require(try await model.completed().scenes.first)
            #expect(hits.best.unit.placement == .boneyard)
            #expect(SearchWording.sceneNumber(hits.best.unit.placement) == WindowWording.boneyardBadge)
            #expect(SearchWording.boneyardSuffix == " · Boneyard")
            model.open(hits.best)
            let opened = try #require(page.book.book.scene(cut.id))
            #expect(page.book.location == .boneyard(opened))
            await eventually {
                page.page.selectedRange() == NSRange(location: 7, length: 7)
                    && page.window.firstResponder === page.page
            }
        }
    }

    @Test func openingAHitInTheOpenSceneSelectsItsMatch() async throws {
        try await withPage([scene("One", body: ["Dawn came.", "The tide went out early."])]) { page in
            let open = page.book.openScene
            let model = page.search
            try await showSheet(page)
            model.text = "early"
            let hit = try #require(try await model.completed().scenes.first?.best)
            model.open(hit)
            #expect(page.book.openScene == open, "the same scene stays open")
            let early = NSRange(location: 11 + 18, length: 5)
            await eventually {
                page.page.selectedRange() == early && page.window.firstResponder === page.page
            }
            #expect((page.storage.string as NSString).range(of: "early") == early, "precondition: the match")
        }
    }
}
