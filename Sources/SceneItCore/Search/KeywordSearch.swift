/// In-memory keyword search over an immutable snapshot of search units (PLAN §9.2).
///
/// Building it splits every unit into words once and interns each distinct spelling's key under
/// every `Comparison`, so a query compares integers. Build it off the main actor with `indexing`.
public struct KeywordSearch: SearchIndex {
    let units: [IndexedUnit]
    let forms: [FormKeys]
    let keyIDs: [[UInt16]: Int32]
    let updateInterval: Duration

    /// A search reports what it has found once `updateInterval` has passed, then after twice
    /// as long, and so on, and when it completes. `.zero` reports after every unit.
    public init(units: [SearchUnit], updateInterval: Duration = .milliseconds(50)) {
        var formIDs: [[UInt16]: Int32] = [:]
        var keyIDs: [[UInt16]: Int32] = [:]
        var forms: [FormKeys] = []
        func key(_ text: [UInt16]) -> Int32 {
            if let id = keyIDs[text] { return id }
            let id = Int32(keyIDs.count)
            keyIDs[text] = id
            return id
        }
        struct SceneKey: Hashable {
            let version: SearchVersion
            let scene: SceneID?
        }
        var sceneOrdinals: [SceneKey: Int] = [:]
        self.units = units.map { unit in
            let sceneKey = SceneKey(version: unit.version, scene: unit.scene?.id)
            let scene = sceneOrdinals[sceneKey] ?? sceneOrdinals.count
            sceneOrdinals[sceneKey] = scene
            let text = Array(unit.text.utf16)
            let tokens = SearchText.tokens(text)
            let tokenForms = tokens.map { token in
                let spelling = Array(text[token.range])
                if let form = formIDs[spelling] { return form }
                let form = Int32(forms.count)
                formIDs[spelling] = form
                forms.append(FormKeys(spelling) { key($0) })
                return form
            }
            return IndexedUnit(unit: unit, scene: scene, tokens: tokens, forms: tokenForms)
        }
        self.forms = forms
        self.keyIDs = keyIDs
        self.updateInterval = updateInterval
    }

    @concurrent public static func indexing(_ units: [SearchUnit]) async -> KeywordSearch {
        KeywordSearch(units: units)
    }

    public func search(_ query: SearchQuery) -> KeywordSearchUpdates {
        KeywordSearchUpdates(indexes: [self], query: query)
    }
}

/// Several keyword indexes searched as one, ranked together as if they were one index: the File
/// Cabinet's, one per filed copy, so a copy filed later is indexed on its own. Reports as the
/// first index's `updateInterval` says.
public struct CombinedKeywordSearch: SearchIndex {
    let indexes: [KeywordSearch]

    public init(_ indexes: [KeywordSearch]) {
        self.indexes = indexes
    }

    public func search(_ query: SearchQuery) -> KeywordSearchUpdates {
        KeywordSearchUpdates(indexes: indexes, query: query)
    }
}

/// The updates of one `KeywordSearch.search` or `CombinedKeywordSearch.search`.
public struct KeywordSearchUpdates: AsyncSequence, Sendable {
    let indexes: [KeywordSearch]
    let query: SearchQuery

    public func makeAsyncIterator() -> Iterator {
        Iterator(stage: .notStarted(indexes, query))
    }

    /// The query is compiled against each index in the first `next()`, off the awaiting actor:
    /// its cost grows with the indexes' vocabularies, and the sheet awaits on the main actor.
    public struct Iterator: AsyncIteratorProtocol {
        var stage: Stage

        enum Stage {
            case notStarted([KeywordSearch], SearchQuery)
            case running(SearchRun)
            case finished
        }

        @concurrent public mutating func next() async -> SearchUpdate? {
            var run: SearchRun
            switch stage {
            case .notStarted(let indexes, let query): run = SearchRun(indexes: indexes, query: query)
            case .running(let current): run = current
            case .finished: return nil
            }
            stage = .finished
            guard let update = run.advance() else { return nil }
            if update.progress != .complete { stage = .running(run) }
            return update
        }
    }
}

struct IndexedUnit: Sendable {
    let unit: SearchUnit
    /// The same for two units of one index exactly when they have the same version and scene (or
    /// are the same copy's own tags).
    let scene: Int
    let tokens: [SearchToken]
    /// Each token's index into `KeywordSearch.forms`.
    let forms: [Int32]
}

/// How a query compares two words.
struct Comparison: Hashable {
    enum Endings: Int, CaseIterable {
        case significant
        /// Words compare without a possessive `'s`, so "bear" is "bear's" but not "bears".
        case possessiveIgnored
        /// Words compare by `SearchText.stem`.
        case ignored
    }

    let sensitivity: SearchText.CaseSensitivity
    let endings: Endings

    static let all = SearchText.CaseSensitivity.allCases.flatMap { sensitivity in
        Endings.allCases.map { Comparison(sensitivity: sensitivity, endings: $0) }
    }

    /// This comparison's index in `all`.
    var ordinal: Int { sensitivity.rawValue * Endings.allCases.count + endings.rawValue }

    /// `spelling` as this comparison sees it.
    func key(_ spelling: [UInt16]) -> [UInt16] {
        let folded = SearchText.folded(spelling, sensitivity)
        return switch endings {
        case .significant: folded
        case .possessiveIgnored: SearchText.withoutPossessive(folded)
        case .ignored: SearchText.stem(folded)
        }
    }
}

/// One spelling's interned key for each `Comparison`.
struct FormKeys: Sendable {
    private let keys: [Int32]

    init(_ spelling: [UInt16], intern: ([UInt16]) -> Int32) {
        keys = Comparison.all.map { intern($0.key(spelling)) }
    }

    subscript(_ comparison: Comparison) -> Int32 {
        keys[comparison.ordinal]
    }
}
