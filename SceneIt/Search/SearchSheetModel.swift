import Observation
import SceneItCore
import SwiftUI

/// The Search sheet's state (PLAN §9.1): the query, its options and scope, and what the engine
/// has reported for them so far. Every change to the query cancels the search in progress and
/// starts another; the sheet keeps showing the last results until the new search reports.
///
/// The book is searched as it was when the sheet last opened (`refresh`): nothing can edit it
/// while the sheet covers the page. The File Cabinet scope searches the book's filed copies, read
/// the first time it runs and kept with the book (`FiledCopyIndexes`), and their own tags as the
/// index has them now.
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
    /// The File Cabinet scope's copy picker and date range. A picked copy the range leaves out is
    /// forgotten.
    var cabinet = CabinetChoice() {
        didSet {
            let fitted = cabinet.fitted(to: book.archive)
            // Observation makes this a computed property, so setting it here comes back through didSet.
            if fitted != cabinet {
                cabinet = fitted
            } else if cabinet != oldValue {
                search()
            }
        }
    }
    /// While a File Cabinet search waits for copies read for the first time: how many are read.
    private(set) var reading: CabinetReading?
    /// The copies the last File Cabinet search couldn't read, so didn't search.
    private(set) var unreadable: [FiledCopyNumber] = []
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
        /// `nil` outside the File Cabinet.
        let cabinet: CabinetChoice?
        let update: SearchUpdate
    }

    struct CabinetReading: Hashable {
        var read: Int
        let of: Int
    }

    struct SceneKey: Hashable {
        let version: SearchVersion
        /// `nil` for a filed copy's own tags.
        let scene: SceneID?

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
        /// The File Cabinet has no copies.
        case noFiledCopies
        /// The File Cabinet has copies, but none in the date range.
        case noCopiesInRange
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
        if scope == .fileCabinet, book.archive.copies.isEmpty { return .noFiledCopies }
        if scope == .fileCabinet, cabinet.searched(in: book.archive).isEmpty { return .noCopiesInRange }
        if text.allSatisfy(\.isWhitespace) { return .prompt(scope) }
        if query.keywords.isEmpty { return .noWords }
        if scope == .thisScene, book.openScene == nil { return .noSceneOpen }
        guard let reported else { return .searching }
        let current =
            reported.query == query && reported.scope == scope && reported.cabinet == cabinetSearched
        return .results(
            SearchListing(reported.update, nearMatches: nearMatches), stale: current ? .current : .stale)
    }

    /// The cabinet choice this scope searches by: `nil` outside the File Cabinet.
    private var cabinetSearched: CabinetChoice? {
        scope == .fileCabinet ? cabinet : nil
    }

    /// The File Cabinet's results grouped by copy, newest first.
    func versions(_ listing: SearchListing) -> [VersionHits] {
        VersionHits.grouped(
            listing.scenes, by: cabinet.searched(in: book.archive).map { .filed($0.number) })
    }

    /// What the File Cabinet has filed as `version`.
    func copy(_ version: SearchVersion) -> FiledCopy? {
        guard case .filed(let number) = version else { return nil }
        return book.archive.copies.first { $0.number == number }
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
    /// ticked, for the sheet opening next. `false`, changing nothing, if the tag has no word to
    /// search for.
    @discardableResult
    func prepare(searchingFor tag: String) -> Bool {
        guard let text = SceneTag.searchText(tag) else { return false }
        scope = .wholeBook
        options = [.searchTags]
        self.text = text
        return true
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
        reading = nil
        unreadable = []
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
        reading = nil
        unreadable = []
        let query = self.query
        let scope = self.scope
        guard !query.keywords.isEmpty else {
            reported = nil
            return
        }
        if scope == .fileCabinet {
            let choice = cabinet
            let copies = choice.searched(in: book.archive)
            run = Task { [weak self] in await self?.searchCabinet(copies, query, choice) }
            return
        }
        let index = index(for: scope)
        run = Task { [weak self] in
            let index = await index.value
            for await update in index.search(query) {
                guard !Task.isCancelled, let self else { return }
                self.reported = Reported(query: query, scope: scope, cabinet: nil, update: update)
            }
        }
    }

    /// Searches `copies`, newest first, and their own tags. Copies not read yet are read first,
    /// all at once off the main actor; meanwhile, with Search tags, the copies' own tags are
    /// searched at once, since the index has them. A copy that can't be read is left out and
    /// listed in `unreadable`.
    private func searchCabinet(_ copies: [FiledCopy], _ query: SearchQuery, _ choice: CabinetChoice) async {
        guard let indexes = book.filedCopyIndexes else { return }
        let numbers = copies.map(\.number)
        let tags = await KeywordSearch.indexing(copies.compactMap(SearchUnit.tags(of:)))
        func report(_ updates: KeywordSearchUpdates) async {
            for await update in updates {
                guard !Task.isCancelled else { return }
                reported = Reported(query: query, scope: .fileCabinet, cabinet: choice, update: update)
            }
        }
        let unread = Set(numbers.filter { !indexes.isLoaded($0) })
        if !unread.isEmpty {
            indexes.prepare(numbers)
            reading = CabinetReading(read: numbers.count - unread.count, of: numbers.count)
            if query.options.contains(.searchTags) { await report(tags.search(query)) }
        }
        var found: [KeywordSearch] = []
        var failed: [FiledCopyNumber] = []
        for number in numbers {
            switch await indexes.index(of: number) {
            case .indexed(let index): found.append(index)
            case .unreadable: failed.append(number)
            }
            guard !Task.isCancelled else { return }
            if unread.contains(number) { reading?.read += 1 }
        }
        reading = nil
        unreadable = failed
        await report(CombinedKeywordSearch([tags] + found).search(query))
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
/// title, the page or the Notes tab; a comment or tag hit shows its tab. A hit in a filed copy
/// opens the copy read-only over the book, and the copy's window opens the hit in turn.
struct SearchOpener {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    let editors: SceneEditors
    let focus: PageFocus
    let mode: Binding<WindowMode>

    func open(_ hit: SearchHit) {
        guard hit.unit.version == book.searchVersion else {
            if case .filed(let number) = hit.unit.version {
                Task { [book, store] in await store.openFiledCopy(number, of: book, showing: hit) }
            }
            return
        }
        guard let id = hit.unit.scene?.id, let scene = book.book.scene(id) else { return }
        book.select(scene.id)
        mode.wrappedValue = mode.wrappedValue.closingSheet
        switch hit.target(in: scene) {
        case .title(let range):
            // A read-only book's title field can't take the focus.
            if book.accepts(.manuscript) { focus.titleSelection.set(NSRange(range), in: scene.id) }
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
