# 07e — The Scenes sheet: a lazy grid, a clock you can inject, fields that appear focused, and an undo that keeps words

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
| [`SceneCard.swift`](../../SceneIt/Window/SceneCard.swift) | the two kinds of card, the tile and the card's title field |
| [`TitleField.swift`](../../SceneIt/Window/TitleField.swift) | the title field the card shares with the page |
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
`ContinuousClock()` and `Date()`. Tests pass `ManualClock` and `ManualWallTime` (both in
`SceneItTestSupport`), wait until the ticker is asleep (`clock.sleeperCount == 1`), then call
`clock.advance(by: .minutes(1))`. Waiting first matters: advancing a clock nobody sleeps on yet
does nothing for the sleep that starts a moment later, so the test would hang under load. It's the same pattern as the
autosave scheduler in 03a: in Rust you'd make the struct generic over a `Clock` trait. Here
`init<C: Clock<Duration>>(clock: C, …)` captures the clock in a closure, so the ticker itself isn't
generic and the app and tests share one type.

The sheet starts the loop with `.task { await model.ticker.run() }`. SwiftUI cancels that task when
the sheet goes away, `sleep` throws `CancellationError`, and the loop returns: cooperative
cancellation, as with a dropped future in Rust. Every card reads `ticker.now`, so Observation redraws
them when it changes. A card reads its age through `ticker.age(of:)`, and the hosted test reads the
same thing, so the test checks exactly what the card shows.

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

The title field is the page's own title field, not a copy: `AdmittingTextField.sceneTitle` makes
both, and both delegates are a `TitleFieldCoordinator` (`TitleField.swift`). The coordinator writes
the title into the book **on every change**, and its Undo is the scene's title history, as on the
page. So a title typed on a card is an edit like any other: autosave saves it, File a Copy files it,
and Quit or Close Book keeps it even if the writer never pressed Return. (A first version kept the
text in the field until Return, and the review caught that closing the book lost it.) Each
subclass adds only its keys: the page's Return goes to the body, the card's Return closes the
field.

Esc closes from the inside out (PLAN §8.4): the sheet's Esc key equivalent first asks the model to
close an open card field, and only if there was none does it close the sheet.

## 5. An undo inverse that keeps words

`addScene` registers its inverse on `structureUndo`, the book's history of structure changes (07):

```swift
        structureUndo.registerUndo(withTarget: self) { $0.takeOut(target, returningTo: previous) }
        structureUndo.setActionName(ScenesWording.newSceneUndoName)
```

The inverse, `takeOut`, has a trust rule (ADR 0041): a scene that holds any of the writer's words
beyond a title goes to the book's hidden Deleted section (ADR 0031), not away. A scene with only a
title, as outlining leaves it, is dropped. The move is `Book.delete(_:from:)`, the same function
that deletes from the Boneyard, so the Deleted-section rule lives in one place.
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
  its undo; the real filter field; a card's click; the ages moving on with the clock; a title typed
  on a card saved when the book closes without Return; and a
  read-only book.

## 7. Moving, cutting and restoring (#29)

PLAN §7.2 and §7.3 add three changes to where a scene is: **move** (drag a card, or Option+arrow),
**cut** (drag onto the Boneyard tray, or Delete) and **restore** (drag a tile onto the grid, or its
↩). They're one enum, `SceneChange`, applied by one method, `OpenBook.change(_:)`.

### The index arithmetic is pure

`Sources/SceneItCore/Model/SceneMoves.swift` holds it, with no UI in sight:

- `StorySlot` is where a scene lands: `.before(SceneID)` or `.end`. Naming a slot by the scene it
  stands before, not by an index, means the answer doesn't depend on whether the moving scene was
  counted. `Book.landing(of:in:)` turns it into an index *after* the scene is taken out.
- `Book.relocate(_:to:)` moves a scene to a `ScenePlace` (a part of the book and an index) and
  returns where it was. That return value is the undo: moving back to it puts everything as it was.
  So `change(_:)` registers `relocate(target, to: from)` as its inverse, and the inverse registers
  the forward move again. One function, its own inverse, for move, cut and restore alike: in Rust
  terms, `fn relocate(&mut self, …) -> Option<Place>` where the `Some` is the undo token.
- Option+arrow uses `Book.slot(takingThePlaceOf:from:)`: the card takes its neighbor's place, after
  it going forward, before it going back. `CardGrid.neighbor(of:_:)` finds the neighbor among the
  cards the filter shows, `columns` to a row, so up and down go a row.

Cutting keeps everything the scene holds, because it's the same `BookScene` value moved from one
array to the other; a test reads `book.md` back to prove it.

### Drag and drop: `onDrag` and a `DropDelegate`

SwiftUI has two drag-and-drop APIs. The newer `draggable(_:)`/`dropDestination(for:)` pair, with a
`Transferable` payload, is the tidy one, but it tells a drop zone only *whether* a drag is over it,
not what kind of drag. The sheet needs that while the drag is in flight: the tray lights red only
for a card, and the slot reads "Restore here" for a Boneyard tile but "Move here" for a card. So it
uses the older pair:

- `onDrag { … }` runs its closure as a drag starts. `ScenesActions.beginDrag(_:)` records what's
  dragged in the sheet's `SceneDropState` and returns an `NSItemProvider` carrying the scene's id
  under the app's own type, `com.samitbasu.SceneIt.scene`, declared in `Config/Info.plist`
  (`UTExportedTypeDeclarations`) and registered with `visibility: .ownProcess`, so no other app can
  receive it.
- `onDrop(of:delegate:)` hands AppKit's drag events to a `SceneDropDelegate`: `validateDrop`,
  `dropEntered`, `dropExited`, `dropUpdated` (which answers `.move`, so the pointer shows no copy
  badge) and `performDrop`. Each just tells `ScenesActions` which `DropZone` it is.

`SceneDropState` (core, pure, tested) turns those enter and exit events into what the sheet draws:
the slot shows before the card the pointer entered, or at the end over the + New scene tile, and it
stays while the pointer is over any zone of the grid, including the slot itself. That matters
because inserting the slot pushes the card it stands before out from under the pointer. It's an
enum, `.idle` or `.dragging(drag, inside:, lastSlot:)`, so there's no "inside" set without a drag.
`slot(in:)` hides a "Move here" that would leave the card where it is.

A drag dropped nowhere tells no drop zone that it ended, and `onDrag` has no end callback. So
`beginDrag` installs a local event monitor (`NSEvent.addLocalMonitorForEvents`) for the mouse
button; when it fires, the drag still recorded on the next turn, after any drop, is over.

The drop zones and drag sources are attached only while the book takes edits. A modifier that's
added or removed changes the view's identity (`_ConditionalContent`), so it's decided by
editability alone, never by a state that changes as the writer types: switching it while a new
card's title field was open made SwiftUI keep the old field in the window.

ADR 0036 (no drag and drop of *text*) is about the editors; it doesn't reach the sheet.

### The keys

The sheet's `UndoFocusView` (07) already holds the focus while the sheet is open, so it takes the
keys too: its `keyHandler` gets each key before AppKit's key bindings, and `CardKey(event)` reads it
as `.focus(step)`, `.move(step)` (with Option), `.cut` (Delete) or `.open` (Return). A key that does
nothing (an arrow at the end of the grid) is passed on, and AppKit beeps. Arrows repeat while held;
Delete and Return ignore `event.isARepeat`, so holding Delete cuts one card. When a card's title or
+ tag field closes, the sheet takes the keys back on the next turn, once SwiftUI has removed the
field. The card focus goes whenever the sheet's view loses the keys (its `focusChanged`), so Delete
can never act on a card the writer stopped looking at.

### Deleting for good

The tile's context menu asks with `BoneyardWording.confirmDelete` through `BookStore.ask(_:)`, the
store's own `StorePrompts`, so hosted tests answer with a scripted prompt object. Then
`deleteFromBoneyard` hides the scene in the Deleted section (ADR 0031), undoable on
`structureUndo`. If it was open, no scene is, and the page says so.

### Tests

- **Core:** `SceneMovesTests` (landing indexes, moves either way, no-op slots, cut, restore, the
  ends, the Deleted section), `SceneDropTests` (the slot, the tray, every drop; the arrow keys at
  the grid's ends), `SceneChangeTests` (each change one named undo step; cut and restore keep notes,
  comments, tags and error entries, in the file byte for byte; read-only).
- **Hosted (`BoneyardTests`):** the drop handlers on the real sheet with the window's Undo and Redo
  and `book.md` read back; the keys sent to the window; ↩; Delete Permanently… with Cancel and
  Delete; a read-only book.
