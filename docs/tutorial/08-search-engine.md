# 08 — The search engine

The Search sheet (PLAN §9.1, issue #31) asks one question: *which paragraphs, comments and tag
sets match this query, best first?* This chapter covers the engine behind it (PLAN §9.2, issue
#30). It teaches five things a Rust programmer meets when writing concurrent library code in
Swift: protocols used as trait objects, `AsyncSequence` compared with Rust's `Stream`, `Sendable`
snapshots, cooperative cancellation, and how a ranking is turned into one comparison.

## Where the code is

Everything lives in [`Sources/SceneItCore/Search/`](../../Sources/SceneItCore/Search/):

| File | What it holds |
| --- | --- |
| [`SearchIndex.swift`](../../Sources/SceneItCore/Search/SearchIndex.swift) | the protocol the Search sheet talks to |
| [`SearchUnit.swift`](../../Sources/SceneItCore/Search/SearchUnit.swift) | the units of text that are searched, and how a `Book` becomes them |
| [`SearchQuery.swift`](../../Sources/SceneItCore/Search/SearchQuery.swift) | the options and the parsed query: words and `"quoted phrases"` |
| [`SearchText.swift`](../../Sources/SceneItCore/Search/SearchText.swift) | words, sentences, case and diacritic folding, and the endings rule |
| [`KeywordSearch.swift`](../../Sources/SceneItCore/Search/KeywordSearch.swift) | the index, and its `AsyncSequence` of updates |
| [`SearchRun.swift`](../../Sources/SceneItCore/Search/SearchRun.swift) | one search in progress: matching, ranking and near matches |
| [`SearchResults.swift`](../../Sources/SceneItCore/Search/SearchResults.swift) | what a search reports: ranks, hits, highlights, updates |

The tests are in [`Tests/SceneItCoreTests/Search/`](../../Tests/SceneItCoreTests/Search/).

---

## 1. Search units: an immutable snapshot

Search never walks the live model. It works on a flat array of `SearchUnit` values, each holding
one paragraph of a title, body or notes, one comment, or a scene's tag set, together with
everything the Search sheet needs to show and open it:

```swift
public struct SearchUnit: Hashable, Sendable {
    public let version: SearchVersion
    public let scene: SceneID
    public let sceneTitle: String
    public let placement: ScenePlacement
    public let field: SearchField
    public let text: String
```

`SearchUnit.units(of:version:)` turns a `Book` into units, story scenes first and then the
Boneyard's, each marked with its `ScenePlacement` (`.story(number:)` or `.boneyard`). The
`version` is `.working` today. When the File Cabinet lands (#34), each decoded filed copy becomes
units the same way with `version: .filed(number)`, and the arrays are simply concatenated.

Every field is a `let`, and every type inside is a value type, so the snapshot can't change
while a search reads it. That is what lets the whole thing be `Sendable` without a lock. In Rust
you'd get the same guarantee from `Arc<[SearchUnit]>` with no interior mutability: the compiler
lets you send it to another thread because nobody can write to it. Swift's `Sendable` is the
analogue of `Send + Sync` for values. A struct is `Sendable` when all its stored properties
are, and the compiler checks that when you declare the conformance.

Building the units is cheap: `Book` is a value type with copy-on-write storage, so taking a
snapshot of the open book on the main actor copies no text until someone writes to the book.

## 2. The protocol as a trait object

The Search sheet shouldn't know which engine it's talking to. PLAN §9.2 expects SQLite FTS5,
`tantivy` or embeddings to slot in later, so the engine sits behind a protocol:

```swift
public protocol SearchIndex<Updates>: Sendable {
    associatedtype Updates: AsyncSequence<SearchUpdate, Never> & Sendable
    func search(_ query: SearchQuery) -> Updates
}
```

In Rust this would be a trait with an associated type:

```rust
trait SearchIndex: Send + Sync {
    type Updates: Stream<Item = SearchUpdate> + Send;
    fn search(&self, query: &SearchQuery) -> Self::Updates;
}
```

and to hold "some index" you'd reach for `Box<dyn SearchIndex<Updates = …>>`, which forces you to
name the associated type or box it as well. Swift's existentials are more forgiving. `<Updates>`
declares `Updates` as the protocol's *primary associated type*, and `any SearchIndex` is a usable
type on its own: calling `search` on it returns the associated type erased to its bound,
`any AsyncSequence<SearchUpdate, Never>`. The test `aSearchIndexIsUsableAsAnExistential` in
[`SearchEngineTests.swift`](../../Tests/SceneItCoreTests/Search/SearchEngineTests.swift) does
exactly that:

```swift
let index: any SearchIndex = KeywordSearch(units: bodyUnits(["a bear"]))
var last: SearchUpdate?
for await update in index.search(SearchQuery("bear")) { last = update }
```

Where the concrete type is known, `some SearchIndex` (like Rust's `impl Trait`) avoids the
existential box entirely; the test helpers take `some SearchIndex`.

## 3. `AsyncSequence` versus Rust's `Stream`

A search reports **progressively**: what it has found after 50 ms, then after another 100 ms,
200 ms and so on, each update replacing the one before, the last marked `.complete`. That is an asynchronous sequence of values, which Rust
spells `Stream` and Swift spells `AsyncSequence`.

The shapes line up closely:

| Rust (`futures::Stream`) | Swift (`AsyncSequence`) |
| --- | --- |
| `fn poll_next(self: Pin<&mut Self>, cx) -> Poll<Option<Item>>` | `mutating func next() async -> Element?` |
| `while let Some(x) = stream.next().await` | `for await x in sequence` |
| `None` ends the stream | `nil` ends the sequence |
| `TryStream` for fallible streams | the `Failure` associated type; here `Never` |

Swift has no `Pin` and no hand-written `poll`: `next()` is an ordinary `async` function, and the
compiler builds the state machine, as `async fn` does in Rust. The `AsyncSequence` itself is like
an `IntoIterator`: `makeAsyncIterator()` gives a fresh iterator, so the same
`KeywordSearchUpdates` value can be iterated twice and each iteration runs its own search.

The engine's iterator is **lazy**. `search(_:)` returns immediately and does no work; each call
to `next()` searches until the next update is due and returns what has been found so far:

```swift
public struct Iterator: AsyncIteratorProtocol {
    var run: SearchRun?

    @concurrent public mutating func next() async -> SearchUpdate? {
        guard var current = run else { return nil }
        run = nil
        guard let update = current.advance() else { return nil }
        if update.progress != .complete { run = current }
        return update
    }
}
```

This is the pull model of a Rust `Stream`: nothing happens unless someone polls. The obvious
alternative, an `AsyncStream` fed by a background `Task`, is push-based: the task runs ahead of
the consumer and has to be cancelled separately when the consumer goes away. With a pull-based
iterator there is no second task to leak.

Two details in that excerpt are worth a second look.

- **`run = nil` before mutating.** `SearchRun` holds arrays. `var current = run` makes a second
  reference to the same buffers, and mutating `current` while `run` still refers to them would
  copy them (copy-on-write). Clearing `run` first leaves `current` the only owner, so `advance()`
  appends in place. Rust's `Option::take()` expresses the same move.
- **`@concurrent`** says this async function always runs on the global concurrent executor,
  never on the caller's actor. The Search sheet will iterate from the main actor, and this keeps
  the scan off it. In this package a plain `nonisolated async` function happens to run on the
  global executor too, but under the app target's approachable concurrency
  ([ADR 0011](../decisions/0011-mainactor-default-isolation.md)) it would run on the caller's
  actor, so the attribute states the intent rather than relying on a build setting. Building the
  index has the same treatment: `KeywordSearch.indexing(_:)` is a `@concurrent static func`.

Why does the interval double? Each update ranks *every* match found so far, so updates at a
fixed cadence would cost ranking work proportional to the matches times the number of
updates, which grows with the search's length. When the intervals double, the work done
before each update grows geometrically, so all the intermediate rankings together cost about
as much as the final one.

## 4. Cancellation is cooperative

Swift tasks, like Rust futures, can't be killed from outside. Rust cancels a future by dropping
it; Swift cancels a task by setting a flag, and the code running in it decides when to stop.
`SearchRun.advance` checks `Task.isCancelled` before every unit, so a cancelled search stops
within one unit (one paragraph, and each unit's matching is linear in its words) and the
sequence ends without a `.complete` update. When the writer
types another letter, the Search sheet cancels the task iterating the old query and starts a new
one.

One test cancels its own task from inside the loop and checks that exactly one update arrived
(`updateInterval: .zero` reports after every unit):

```swift
let received = await Task {
    var received: [SearchUpdate] = []
    for await update in index.search(SearchQuery("bear")) {
        received.append(update)
        withUnsafeCurrentTask { $0?.cancel() }
    }
    return received
}.value
#expect(received.map(\.progress) == [.searching(unitsSearched: 1, of: 100)])
```

Because the iterator is lazy, that single update is also proof that nothing more was searched:
the work only ever happens inside `next()`. A second test,
`cancellingStopsASearchOfHugeParagraphsPromptly` in
[`SearchPerformanceTests.swift`](../../Tests/SceneItCoreTests/Search/SearchPerformanceTests.swift),
cancels a search of 40 paragraphs of 20,000 words each from outside, while its one long
`advance()` is running, and checks that it stops in under half the time the whole search takes.

## 5. Words, sentences and endings

**Words.** A search word is a maximal run of letters and digits, which may hold an apostrophe
between two of them ("don't", "bear's"). Anything else separates words. This deliberately
differs from the word count's definition
([ADR 0023](../decisions/0023-word-count-like-word.md)), where "well-known" and "dawn--and" are
one word each, as in Microsoft Word: a count must agree with the writer's exported document, but
a search must find "known" in "well-known" and "bear" in "(bear),".

**Sentences.** A sentence ends at a line break, and after a run of `.`, `!` or `?` that is
followed, once any closing `"`, `'`, `)` and `]` are skipped, by whitespace or the end of the
text. That is all: "Mr. Smith" is two sentences (an accepted imprecision), while "e.g" and
"3.14" end none. `SearchText.tokens` tags each word with its sentence as it goes.

**Folding.** Matching ignores case and diacritics. Rather than hand-write which Latin-1 letter
folds to what, `SearchText` asks Foundation once per character and keeps the answers in a table:

```swift
private static func table(_ options: String.CompareOptions) -> [[UInt16]] {
    (0..<0x100).map { value in
        Array(
            String(Character(Unicode.Scalar(UInt8(value)))).folding(options: options, locale: nil)
                .utf16)
    }
}
```

A table entry can be longer than one character (`ß` folds to `ss`), which is why folding builds a
key for each word rather than rewriting the text in place, and why highlight ranges always point
into the original text. When strict ASCII lands
([ADR 0028](../decisions/0028-strict-ascii-no-input-methods.md), #74), there are no diacritics
left to fold, case folding is ASCII lowercasing, and the table could shrink to 128 one-character
entries.

**Endings.** By default a query word matches any word with the same *stem*, so "bear" matches
"bears", "bear's" and "Bears'". The rule is deliberately small, documented on
`SearchText.stem`, and pinned case by case in `theStemmingRule`:

| Rule | Examples |
| --- | --- |
| 1. "news" and "does" are kept whole | news, does |
| 2. A possessive `'s` is removed and the rest is stemmed again | bear's → bear, it's → it, James's → James → Jame (as James) |
| 3a. Only when at least 3 characters remain: `es` is removed after `ss`, `x`, `zz`, `ch`, `sh` or `o` | kisses → kiss, boxes → box, buzzes → buzz, churches → church, heroes → hero, echoes → echo |
| 3b. Otherwise, with the same minimum, `s` is removed unless it follows another `s` | bears → bear, sizes → size, horses → horse, menus → menu, taxis → taxi, skis → ski; glass, his and bus are kept |
| 4. A final `ie` becomes `y` | movie, movies → movy; lady, ladies → lady; tie, ties → ty |

A stem doesn't have to be a word ("Jame", "movy"): it only has to be the same for the forms
that should match. The rule accepts some false positives (Hans, Carlos and Mars lose their `s`,
so "Han" finds "Hans"; Whole word is the escape hatch) and doesn't know irregular plurals
(mice, children) or words like "shoes" (stem "sho", while "shoe" stays "shoe").

**Whole word** turns the endings off. **Match case** makes case significant (diacritics stay
ignored). A `"quoted phrase"` always compares words exactly, adjacent and within one sentence.

### Interning: comparing integers

`KeywordSearch.init` reads every unit once. For each distinct spelling it computes four keys,
one per combination of case sensitivity and endings, and interns each key as an `Int32`. A
query then maps each distinct spelling to the word keyword it matches, if any
(`CompiledQuery.wordKeywordOfForm`), so scanning 120,000 tokens is 120,000 array lookups. It's
the same trick as a Rust `string_interner`, built from a `[[UInt16]: Int32]` dictionary.

## 6. Ranking as one comparison

PLAN §9.2 fixes the order: **coverage** (distinct keywords matched), then the **proximity tier**
(all matched words in one sentence, then within one paragraph), then a **fine score**. A strict
priority order like that is a lexicographic comparison, so it's encoded once, as a `Comparable`
struct whose `<` compares a tuple:

```swift
public struct Rank: Comparable, Hashable, Sendable {
    /// The number of distinct keywords matched.
    public let coverage: Int
    public let tier: ProximityTier
    public let fine: FineScore

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.coverage, lhs.tier, lhs.fine) < (rhs.coverage, rhs.tier, rhs.fine)
    }
}
```

Swift tuples of `Comparable` values compare lexicographically, as Rust's tuples do with
`#[derive(PartialOrd, Ord)]` on a struct (which compares fields in declaration order). The
difference is that Swift won't derive `Comparable` for a struct, so you write the one line
yourself, and the order of the tuple is the policy.

The fine score blends the remaining signals, with every weight in `RankingWeights`:

```
fine = Σ over matched keywords k of  idf(k) × (1 + 0.25 × ln(occurrences of k))
     + 2 × compactness  +  1 × adjacency  +  field boost
```

- **Rarity:** `idf(k) = ln(1 + units searched / units containing k)`.
- **Repeats:** the logarithm gives diminishing returns.
- **Compactness:** `1 / (1 + the number of other words in the smallest window that holds every
  matched keyword)`, taken within a sentence when the tier is `.sentence`.
- **Adjacency:** the fraction of neighbouring query keywords that are also neighbours in the text,
  in query order ("bear claw" beats "claw bear").
- **Boost:** 1 for a title, 0.5 for a tag set.

Ranks are only compared within one search, so the fine score's scale means nothing outside it.
Since rarity depends on every unit searched so far, `UnitMatch` keeps the ingredients rather than
the score, and each update recomputes the ranks: an early update ranks with the rarity it knows,
and the final one is exact.

Each ranking test in
[`SearchRankingTests.swift`](../../Tests/SceneItCoreTests/Search/SearchRankingTests.swift) pins
one tier against the next by giving the unit that should lose the better score on every *later*
criterion, and asserts that precondition, so the test can't pass by accident:

```swift
#expect(first.rank.coverage == 2 && first.rank.tier == .paragraph, "precondition")
#expect(second.rank.coverage == 1 && second.rank.tier == .sentence, "precondition")
#expect(second.rank.fine > first.rank.fine, "precondition")
#expect(first.rank > second.rank)
```

Hits are then grouped by scene, scenes ordered by their best hit; `SceneHits.moreCount` is the
Search sheet's "+N more in this scene".

## 7. Near matches

When no unit contains every keyword, the update's `quality` is `.near` and it holds the best
partial matches instead. Each near hit highlights the matched words as `.match` and marks the
words that stand where a missing keyword would be as `.differs`: for each matched keyword, the
engine walks outward over the run of missing keywords beside it in the query and marks the words
in the same positions in the text, within the sentence. Searching "bear claw" in "The bear paw
prints" highlights "bear" and marks "paw".

## 8. Highlights are UTF-16 offsets

`Highlight.range` counts UTF-16 code units into `SearchUnit.text`, because that is what AppKit's
`NSRange` counts, so the Search sheet can hand a range straight to the editor once it has added
the paragraph's offset within the scene. Model text is Latin-1 (and soon ASCII), so these are
also character offsets. The seeded property test in
[`SearchPropertyTests.swift`](../../Tests/SceneItCoreTests/Search/SearchPropertyTests.swift)
compares the engine, over 300 random books and queries, with an *oracle*: the documented rules
for words, sentences, folding and endings written again from scratch, simply and slowly, sharing
no code with the engine but the query parser. It checks that the units reported are exactly the
ones the oracle expects, that each hit's coverage and tier agree, and that the `.match`
highlights are exactly the oracle's occurrences, merged: every occurrence, and nothing else.

## 9. Performance

PLAN §9.2 asks for about 100 ms on a 120,000-word working book, and about 500 ms across 50
filed copies. On the development machine a release build indexes such a book in about 14 ms
and answers a query in about 3 ms. Fifty copies of it (72,000 units, with the test novel's
ten-word vocabulary, so that most units match every query) take 80 to 330 ms per query,
progressive updates included. A debug build is far slower (about 80 ms for both
indexing and a query on the one book), so
[`SearchPerformanceTests.swift`](../../Tests/SceneItCoreTests/Search/SearchPerformanceTests.swift)
asserts only a generous ceiling and that doubling the input about doubles the time, in the
style of the format's `PerformanceTests`, so that it can't flake. One of its cases is a single
paragraph of 100,000 words whose only window holding both keywords is the whole paragraph: a
window search that rescanned its window as it shrank would be quadratic there.
