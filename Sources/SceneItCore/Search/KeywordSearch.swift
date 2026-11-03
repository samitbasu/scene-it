/// In-memory keyword search over an immutable snapshot of search units (PLAN §9.2).
///
/// Building it splits every unit into words once and interns each distinct spelling's four
/// comparison keys, so a query compares integers. Build it off the main actor with `indexing`.
public struct KeywordSearch: SearchIndex {
    let units: [IndexedUnit]
    let forms: [FormKeys]
    let keyIDs: [[UInt16]: Int32]
    let unitsPerUpdate: Int

    /// `unitsPerUpdate` units are searched between updates.
    public init(units: [SearchUnit], unitsPerUpdate: Int = 512) {
        var formIDs: [[UInt16]: Int32] = [:]
        var keyIDs: [[UInt16]: Int32] = [:]
        var forms: [FormKeys] = []
        func key(_ text: [UInt16]) -> Int32 {
            if let id = keyIDs[text] { return id }
            let id = Int32(keyIDs.count)
            keyIDs[text] = id
            return id
        }
        self.units = units.map { unit in
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
            return IndexedUnit(unit: unit, tokens: tokens, forms: tokenForms)
        }
        self.forms = forms
        self.keyIDs = keyIDs
        self.unitsPerUpdate = max(1, unitsPerUpdate)
    }

    @concurrent public static func indexing(_ units: [SearchUnit]) async -> KeywordSearch {
        KeywordSearch(units: units)
    }

    public func search(_ query: SearchQuery) -> KeywordSearchUpdates {
        KeywordSearchUpdates(index: self, query: query)
    }
}

/// The updates of one `KeywordSearch.search`.
public struct KeywordSearchUpdates: AsyncSequence, Sendable {
    let index: KeywordSearch
    let query: SearchQuery

    public func makeAsyncIterator() -> Iterator {
        Iterator(run: SearchRun(index: index, query: query))
    }

    public struct Iterator: AsyncIteratorProtocol {
        var run: SearchRun?

        @concurrent public mutating func next() async -> SearchUpdate? {
            guard var current = run, !Task.isCancelled else {
                run = nil
                return nil
            }
            run = nil
            let update = current.advance()
            if update.progress != .complete { run = current }
            return update
        }
    }
}

struct IndexedUnit: Sendable {
    let unit: SearchUnit
    let tokens: [SearchToken]
    /// Each token's index into `KeywordSearch.forms`.
    let forms: [Int32]
}

/// How a query compares two words.
struct Comparison: Hashable {
    enum Endings: Hashable {
        case significant
        /// Words compare by `SearchText.stem`.
        case ignored
    }

    let sensitivity: SearchText.CaseSensitivity
    let endings: Endings

    /// `spelling` as this comparison sees it.
    func key(_ spelling: [UInt16]) -> [UInt16] {
        let folded = SearchText.folded(spelling, sensitivity)
        return endings == .ignored ? SearchText.stem(folded) : folded
    }
}

/// One spelling's interned key for each `Comparison`.
struct FormKeys: Sendable {
    private let exactInsensitive, exactSensitive, stemInsensitive, stemSensitive: Int32

    init(_ spelling: [UInt16], intern: ([UInt16]) -> Int32) {
        func id(_ sensitivity: SearchText.CaseSensitivity, _ endings: Comparison.Endings) -> Int32 {
            intern(Comparison(sensitivity: sensitivity, endings: endings).key(spelling))
        }
        exactInsensitive = id(.insensitive, .significant)
        exactSensitive = id(.sensitive, .significant)
        stemInsensitive = id(.insensitive, .ignored)
        stemSensitive = id(.sensitive, .ignored)
    }

    subscript(_ comparison: Comparison) -> Int32 {
        switch (comparison.sensitivity, comparison.endings) {
        case (.insensitive, .significant): exactInsensitive
        case (.sensitive, .significant): exactSensitive
        case (.insensitive, .ignored): stemInsensitive
        case (.sensitive, .ignored): stemSensitive
        }
    }
}
