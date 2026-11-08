import Observation
import SceneItCore
import SwiftUI

/// The Search sheet's state (PLAN §9.1): the query, its options and scope, and what the engine
/// has reported for them so far. Every change to the query cancels the search in progress and
/// starts another; the sheet keeps showing the last results until the new search reports.
///
/// The book is searched as it was when the sheet last opened (`refresh`): nothing can edit it
/// while the sheet covers the page.
@Observable
final class SearchSheetModel {
    typealias Indexing = @Sendable ([SearchUnit]) async -> any SearchIndex

    let book: AppOpenBook
    var text = "" {
        didSet { if text != oldValue { search() } }
    }
    var options: SearchOptions = [] {
        didSet { if options != oldValue { search() } }
    }
    var scope = SearchScope.wholeBook {
        didSet { if scope != oldValue { search() } }
    }
    private(set) var nearMatches = NearMatchLimit.best
    /// The scenes whose "+N more" the writer opened.
    private(set) var expanded: Set<SceneKey> = []
    /// The last update of the latest search to report, and what it searched for.
    private(set) var reported: Reported?

    /// What opening a hit does; the window sets it.
    @ObservationIgnored var opener: SearchOpener?
    @ObservationIgnored private let indexing: Indexing
    @ObservationIgnored private var indexes: [SearchScope: Task<any SearchIndex, Never>] = [:]
    @ObservationIgnored private var run: Task<Void, Never>?

    struct Reported: Hashable {
        let query: SearchQuery
        let scope: SearchScope
        let update: SearchUpdate
    }

    struct SceneKey: Hashable {
        let version: SearchVersion
        let scene: SceneID

        init(_ hits: SceneHits) {
            version = hits.version
            scene = hits.scene
        }
    }

    static let keywordIndexing: Indexing = { await KeywordSearch.indexing($0) }

    init(book: AppOpenBook, indexing: @escaping Indexing = keywordIndexing) {
        self.book = book
        self.indexing = indexing
    }

    isolated deinit {
        run?.cancel()
    }

    var query: SearchQuery {
        SearchQuery(text, options: options)
    }

    enum State: Hashable {
        /// Nothing typed yet.
        case prompt(SearchScope)
        /// Typed, but no words in it.
        case noWords
        case noSceneOpen
        /// Nothing reported yet.
        case searching
        /// `stale` while a newer search hasn't reported yet.
        case results(SearchListing, stale: Staleness)
    }

    enum Staleness: Hashable {
        case current, stale
    }

    var state: State {
        let query = self.query
        if text.allSatisfy(\.isWhitespace) { return .prompt(scope) }
        if query.keywords.isEmpty { return .noWords }
        if scope == .thisScene, book.openScene == nil { return .noSceneOpen }
        guard let reported else { return .searching }
        let current = reported.query == query && reported.scope == scope
        return .results(
            SearchListing(reported.update, nearMatches: nearMatches), stale: current ? .current : .stale)
    }

    func isOn(_ checkbox: SearchCheckbox) -> Bool {
        options.contains(checkbox.option)
    }

    func set(_ checkbox: SearchCheckbox, _ state: CheckboxState) {
        switch state {
        case .on: options.insert(checkbox.option)
        case .off: options.remove(checkbox.option)
        }
    }

    enum CheckboxState {
        case on, off
    }

    /// The Tags tab's ⌕ (PLAN §8.3): `tag` searched in the whole book, with only Search tags
    /// ticked, for the sheet opening next.
    func prepare(searchingFor tag: String) {
        scope = .wholeBook
        options = [.searchTags]
        text = SceneTag.searchText(tag)
    }

    func showAllNearMatches() {
        nearMatches = .all
    }

    func isExpanded(_ hits: SceneHits) -> Bool {
        expanded.contains(hits.key)
    }

    func toggleExpanded(_ hits: SceneHits) {
        let key = SceneKey(hits)
        if expanded.remove(key) == nil { expanded.insert(key) }
    }

    func open(_ hit: SearchHit) {
        opener?.open(hit)
    }

    /// Searches the book as it is now, as the sheet opens. What an earlier opening found is
    /// never shown: the book may have changed since, under its offsets.
    func refresh() {
        close()
        search()
    }

    /// As the sheet closes: stops the search and lets go of the indexes and the results.
    func close() {
        run?.cancel()
        run = nil
        for index in indexes.values { index.cancel() }
        indexes = [:]
        reported = nil
    }

    /// Waits until no search is in progress: the latest one has finished or been cancelled,
    /// including any started while waiting.
    func settle() async {
        while let current = run {
            await current.value
            if run == current { return }
        }
    }

    private func search() {
        run?.cancel()
        run = nil
        nearMatches = .best
        expanded = []
        let query = self.query
        let scope = self.scope
        guard !query.keywords.isEmpty else {
            reported = nil
            return
        }
        let index = index(for: scope)
        run = Task { [weak self] in
            let index = await index.value
            for await update in index.search(query) {
                guard !Task.isCancelled, let self else { return }
                self.reported = Reported(query: query, scope: scope, update: update)
            }
        }
    }

    private func index(for scope: SearchScope) -> Task<any SearchIndex, Never> {
        if let index = indexes[scope] { return index }
        let book = self.book.book
        let openScene = self.book.openScene
        let indexing = self.indexing
        let index = Task {
            await indexing(await Self.units(of: book, in: scope, openScene: openScene))
        }
        indexes[scope] = index
        return index
    }

    @concurrent private static func units(of book: Book, in scope: SearchScope, openScene: SceneID?) async
        -> [SearchUnit]
    {
        scope.units(of: SearchUnit.units(of: book, version: .working), openScene: openScene)
    }
}

/// Opens a hit (PLAN §9.1): its scene, with the sheet closed, and its match selected in the
/// title, the page or the Notes tab; a comment or tag hit shows its tab.
struct SearchOpener {
    let book: AppOpenBook
    let preferences: AppPreferences
    let editors: SceneEditors
    let focus: PageFocus
    let mode: Binding<WindowMode>

    func open(_ hit: SearchHit) {
        guard let scene = book.book.scene(hit.unit.scene) else { return }
        book.select(scene.id)
        mode.wrappedValue = mode.wrappedValue.closingSheet
        switch hit.target(in: scene) {
        case .title(let range):
            // A read-only book's title field can't take the focus.
            if book.isEditable { focus.titleSelection.set(NSRange(range), in: scene.id) }
        case .text(.body, let range):
            editors.page.editor.reveal(NSRange(range), in: scene.id)
        case .text(.notes, let range):
            preferences.reveal(.notes)
            editors.notes.editor.reveal(NSRange(range), in: scene.id)
        case .comment:
            // Selecting the comment's card arrives with the Comments tab's cards (#25).
            preferences.reveal(.comments)
        case .tags:
            preferences.reveal(.tags)
        case .scene:
            break
        }
    }
}

extension SceneHits {
    /// Which scene of which version these are, which the sheet identifies its groups by.
    var key: SearchSheetModel.SceneKey {
        SearchSheetModel.SceneKey(self)
    }
}
