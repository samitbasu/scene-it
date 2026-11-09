# 07d — The Scenes sheet: a lazy grid, a clock you can inject, fields that appear focused, and an undo that keeps words

The Scenes sheet (PLAN §7.2, issue #28) is ⌘1: the story as cards or as a dense light table, a filter,
+ New scene, and tags on the cards. This chapter covers what's new to a Rust programmer here:
- `LazyVGrid` and adaptive columns, and why "lazy" matters for a SwiftUI list of views;
- keeping "3 hours ago" true on screen with a ticker whose clock is injected, the same `Clock` idea
  as the autosave scheduler (03a);
- a text field that takes the focus as it appears, and why that's harder than it sounds;
- an undo inverse that never destroys words;
- reusing the Tags tab's field and chip rather than forking them.

## Where the code is

| File | What it holds |
| --- | --- |
| [`SceneCards.swift`](../../Sources/SceneItCore/Window/SceneCards.swift) | `ScenesView`, `SceneExcerpt` (the first sentence), `SceneFilter`, `RelativeAge` |
| [`MinuteTicker.swift`](../../Sources/SceneItCore/Window/MinuteTicker.swift) | the time the cards' ages are measured against |
| [`ScenesWording.swift`](../../Sources/SceneItCore/Window/ScenesWording.swift) | every string, the totals and "6 hours ago" |
| [`OpenBook.swift`](../../Sources/SceneItCore/Store/OpenBook.swift) | `addScene` and its undo on `structureUndo` |
| [`ScenesActions.swift`](../../SceneIt/Window/ScenesActions.swift) | the sheet's model and what its buttons do |
| [`ScenesSheet.swift`](../../SceneIt/Window/ScenesSheet.swift) | the header and the grid |
| [`SceneCard.swift`](../../SceneIt/Window/SceneCard.swift) | the two kinds of card, the tile and the title field |
| [`NewTagField.swift`](../../SceneIt/Window/NewTagField.swift) | the + tag field, shared with the Tags tab |

Tests: [`SceneCardsTests.swift`](../../Tests/SceneItCoreTests/Window/SceneCardsTests.swift) and
[`AddSceneTests.swift`](../../Tests/SceneItCoreTests/Store/AddSceneTests.swift) (core), and
[`ScenesSheetTests.swift`](../../SceneItTests/ScenesSheetTests.swift) (the real window).

## 1. Pure parts first

Everything a card *computes* is a pure function in core: the excerpt, the filter, the age bucket,
the totals. The view only lays them out. That's the same split as the Tags tab (07b): in Rust terms,
the views are a thin `impl Display` over plain functions you can unit-test without a window.

One detail is worth copying. A card's first sentence uses **search's** sentence rule, not a new
one. `SearchText` already decided that "Mr. Smith" is two sentences and "3.5" ends none; the excerpt
calls `SearchText.firstSentenceEnd`, which shares its terminal-run helper with the tokenizer. A test
checks that the two agree on a set of tricky inputs, so they can't drift.

`RelativeAge` is an enum, not a string. The bucketing ("59 seconds is just now, 24–48 hours is
yesterday") is tested as data; the words come from Foundation's `RelativeDateTimeFormatter`, given
exact `DateComponents` such as `hour: -6`. Using the formatter rather than hand-built strings is the
CLAUDE.md rule "use the library that already computes it". The age is an `Interval` (ADR 0010), so
a modified date in the future (a clock set back) clamps to zero and reads "just now", with no
special case.

## 2. `LazyVGrid` and adaptive columns

```swift
LazyVGrid(columns: columns, alignment: .leading, spacing: WindowMetrics.Scenes.gap) {
    ForEach(shown, id: \.scene.id) { entry in
        card(entry.scene, number: entry.number)
            .id(entry.scene.id)
    }
```

`GridItem(.adaptive(minimum: 240))` means "as many columns as fit, each at least 240 pt". So the
grid is five cards wide in the default window and reflows as the window narrows, with no layout code
of ours. The light table asks for 150 pt and gets eight.

*Lazy* means SwiftUI only builds the views for cards on screen and a few beyond, like an iterator
that isn't collected. With 200 scenes, the 180 off screen cost nothing until you scroll. The
consequence: a card's view, and any AppKit field in it, may not exist yet. That matters in §4.

`ForEach(…, id: \.scene.id)` is how SwiftUI knows which card is which across updates, like a key in
a React list. Using the scene's id (not its index) means adding a scene in the middle doesn't make
every later card think it's a different scene.

`.id(entry.scene.id)` plus a `ScrollViewReader` lets the sheet scroll to a scene just added:
`proxy.scrollTo(scene)`.

## 3. Keeping "3 hours ago" true

A card shows how long ago its scene changed. If nothing redraws it, "just now" is still on screen an
hour later. SwiftUI has `TimelineView(.everyMinute)` for this, but a test can't make a minute pass.
So the sheet uses `MinuteTicker`, an `@Observable` object with a `now` that changes once a minute:

```swift
    public func run() async {
        now = wallTime()
        while true {
            do {
                try await sleep(period)
            } catch {
                return
            }
            now = wallTime()
        }
    }
```

Two things are injected: the **clock** it sleeps on and the **wall time** it reads. The app passes
`ContinuousClock()` and `Date()`. Tests pass `ManualClock` (now shared in `SceneItTestSupport`) and
a date they move by hand, then call `clock.advance(by: .minutes(1))`. It's the same pattern as the
autosave scheduler in 03a: in Rust you'd make the struct generic over a `Clock` trait. Here
`init<C: Clock<Duration>>(clock: C, …)` captures the clock in a closure, so the ticker itself isn't
generic and the app and tests share one type.

The sheet starts the loop with `.task { await model.ticker.run() }`. SwiftUI cancels that task when
the sheet goes away, `sleep` throws `CancellationError`, and the loop returns: cooperative
cancellation, as with a dropped future in Rust. Every card reads `ticker.now`, so Observation redraws
them when it changes. The hosted test proves it by drawing the window to a bitmap before and after
the clock moves.

## 4. A field that appears focused

A new scene's card shows a title field you can type into at once, and + tag opens a field with the
cursor in it. "Make it first responder when it appears" sounds like one line:

```swift
DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
```

It isn't enough, for two reasons this sheet hit:
- In a lazy grid, the field may be created before it's in a window. `field.window` is `nil` on the
  next turn, and nothing happens.
- Asking a field to become first responder **while it's already editing** ends that editing first.
  For the title field, ending means "accept the title and close", so the field closed itself.

So `AdmittingTextField` has a small hook: `firstFocus = .pending` makes it take the focus in
`viewDidMoveToWindow`, once it's really in a window, and only if it isn't being edited already.
It's an AppKit override because SwiftUI's `@FocusState` (07c) works for SwiftUI's own fields, and
these are AppKit fields (ADR 0028's no-input-method editor).

The title field also never loses what was typed. It accepts on Return, but also whenever editing
ends for any other reason (Tab, a click away, Esc, the sheet closing). It keeps the typed text as it
changes (`AdmittingTextView.onChange`) rather than reading the field at the end, because by the time
SwiftUI tears the view down its editor may already be gone.

Esc closes from the inside out (PLAN §8.4): the sheet's Esc key equivalent first asks the model to
close an open card field, and only if there was none does it close the sheet.

## 5. An undo inverse that keeps words

`addScene` registers its inverse on `structureUndo`, the book's history of structure changes (07):

```swift
        structureUndo.registerUndo(withTarget: self) { $0.takeOut(target, returningTo: previous) }
        structureUndo.setActionName(ScenesWording.newSceneUndoName)
```

The inverse, `takeOut`, has a trust rule (ADR 0041): a scene that holds anything the writer wrote
goes to the book's hidden Deleted section (ADR 0031), not away. Only a blank scene is dropped.
Redo puts it back from wherever it went. In Rust terms, the inverse's captured state is an enum,
`Unadded.held(BookScene)` or `.deleted`, so the redo can't be confused about where the scene is.

`StructureTarget` is the same indirection `deleteFromBoneyard` uses: the undo names the scene by a
token whose id an Errors-tab Fix can change, so a later undo still finds it.

## 6. Reuse, not fork

Cards tag scenes through the Tags tab's own `TagActions` and the same `TagChip`. The + tag field was
private to the Tags tab, so it moved to `NewTagField.swift` and now takes closures: what Return adds,
and where Esc sends the focus (the page in the Tags tab, nowhere in the sheet). A card's tag is a
step on that scene's page undo, as in the Tags tab. The Search sheet's numbered circle moved to
`SceneNumber.swift` for the cards. Two copies of either would drift (CLAUDE.md: tech debt).

## Tests

- **Core:** the excerpt (the sentence rule, the 120-character cut), the filter (title, text, tags,
  `#word`), the age buckets and their words, the totals, the ticker on a `ManualClock`, and adding a
  scene with its undo and redo (blank, holding words, read-only).
- **Hosted:** View → Scenes on ⌘1 in the app's own window; both add buttons with the title typed on
  the card, the window's Undo and Redo; Esc closing the field and then the sheet; + tag on a card and
  its undo; the real filter field; a card's click; the ages redrawing when the clock moves; and a
  read-only book.
