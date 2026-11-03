/// A search engine the Search sheet can use without knowing which one it is (PLAN §9.2): keyword
/// search today; SQLite FTS5, `tantivy` or embeddings could conform later.
///
/// `search` returns at once and does no work: the work happens as the updates are awaited, off
/// the awaiting actor, a batch per update. Each update replaces the one before, and the last is
/// `.complete`. Cancelling the awaiting task ends the sequence early, at the next batch.
public protocol SearchIndex<Updates>: Sendable {
    associatedtype Updates: AsyncSequence<SearchUpdate, Never> & Sendable
    func search(_ query: SearchQuery) -> Updates
}
