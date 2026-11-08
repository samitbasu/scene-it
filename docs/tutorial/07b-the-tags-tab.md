# 07b — The Tags tab: a pure sort, field-wise undo, a custom `Layout`, and a switchable look

The Tags tab (PLAN §8.3, issue #20) shows the open scene's tags as chips with a **+ tag** field,
then every tag in the book with how many scenes use it. A click on a row toggles the tag on the
open scene, and a row's ⌕ opens Search on it. This chapter teaches four things a Rust programmer
meets here:
- a sort and a spelling rule as pure functions in core, so they're tested without a window;
- undo inverses that put back only what they took, on another view's undo manager;
- SwiftUI's `Layout` protocol, for chips that wrap;
- keeping look candidates in one switchable place until the owner picks.

## Where the code is

| File | What it holds |
| --- | --- |
| [`BookTags.swift`](../../Sources/SceneItCore/Model/BookTags.swift) | `BookTags` (the list, its sort, the book's spelling) and `SceneTag` (one tag: typed, compared, searched) |
| [`OpenBook.swift`](../../Sources/SceneItCore/Store/OpenBook.swift) | `addTag`, `removeTag`, `toggleTag`, and their undo on the page's manager |
| [`TagWording.swift`](../../Sources/SceneItCore/Window/TagWording.swift) | every string the tab shows, and the undo names |
| [`TagsTab.swift`](../../SceneIt/Window/TagsTab.swift) | the tab, `TagActions`, the + tag field, and `TagsLook`, the candidates |
| [`ChipFlow.swift`](../../SceneIt/Window/ChipFlow.swift) | the wrapping layout, shared with File a Copy's tags |

The tests are [`BookTagsTests.swift`](../../Tests/SceneItCoreTests/Model/BookTagsTests.swift) and
[`TagEditTests.swift`](../../Tests/SceneItCoreTests/Store/TagEditTests.swift) (core), and
[`TagsTabTests.swift`](../../SceneItTests/TagsTabTests.swift) (the real window).

## 1. The sort is a value, not a view

`BookTags(book)` is the whole list: each tag once, with its scene count, most-used first, ties
alphabetical ignoring case. The view only draws `entries`. In Rust you'd write a free function
returning a `Vec<Entry>`; here it's a struct whose `init` does the work, because Swift has no
separate constructor functions and an initializer that computes is idiomatic.

```swift
    static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            $0.scenes != $1.scenes ? $0.scenes > $1.scenes : SceneTag.key($0.tag) < SceneTag.key($1.tag)
        }
    }
```

`sorted(by:)` takes an "are these in increasing order" closure, like Rust's `sort_by` but
returning `Bool` instead of an `Ordering`. Swift has no `Ordering::then`; a ternary on the first
key is the usual spelling. The sort is stable in practice but Swift doesn't promise that, so the
tie-breaker must decide every tie. Here it does: two entries never share a key, because case
variants were merged into one entry first.

**Case.** Tags that differ only in case are one tag (the owner, #20). `SceneTag.key` lowercases;
that's exact because the book holds only ASCII (ADR 0028), so there's no Unicode case-folding to
worry about. If the book has both `Mara` and `mara`, the list shows the spelling the most scenes
use, and on a tie the first in code-point order, so `Mara` beats `mara`. `BookTags.spelling(of:)`
gives a typed tag that spelling, which is how typing `mara` adds `Mara`. One function decides it,
so the + field and a row click can't disagree.

## 2. Undo that puts back only its own change

The owner chose to put tag edits on the scene's **page** undo manager, as comment actions are
(PLAN §8.6). So ⌘Z on the page takes back a tag edit or the typing around it, in the order they
happened. `OpenBook.insertTag` registers `deleteTag` as its inverse, and `deleteTag` registers
`insertTag` at the index it removed from:

```swift
        registerPageUndo(in: scene, named: name) { [removed = tags[index]] in
            _ = $0.insertTag(removed, at: index, in: scene, named: name)
        }
```

The closure's capture list `[removed = tags[index]]` copies the value now, like a Rust `move`
closure over a fresh binding. Each inverse changes only the tag list, never the whole scene, so
undoing a tag edit can't take back typing made after it. And the inverse registers its own
inverse, which is how redo works: `UndoManager` turns what an undo registers into the redo step.
`registerPageUndo` doesn't rename while undoing or redoing (#125), so Redo reads "Redo Add Tag",
not whatever the inverse would call itself.

Since the step lives on the page's manager, ⌘Z only reaches it while the page has the focus. So
every tag action hands the focus to the page (`TagActions.edit`), and Return in the + field does
too. Before the edit it calls `breakUndoCoalescing()` on the page, so the typing before the tag
edit and the typing after it stay separate steps rather than one long "Typing".

## 3. A `Layout` for chips

SwiftUI's stacks don't wrap. `ChipFlow` conforms to the `Layout` protocol: two methods,
`sizeThatFits` (how big am I for this offer?) and `placeSubviews` (where does each child go?). A
child is asked its size with a `ProposedViewSize`: `.unspecified` means "your ideal size", and a
width means "you have this much". A chip whose ideal is wider than the whole line is asked again
with the line's width, so its `Text` truncates with `…` instead of overflowing:

```swift
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > line.points {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: line.points, height: nil))
            }
```

This is closer to a Rust UI crate's two-pass measure-then-arrange than to CSS: the parent offers,
the child answers, the parent decides. File a Copy's tag field already had this layout; it moved
to its own file so both use one implementation.

## 4. Look candidates in one place

Aesthetic choices are the owner's (CLAUDE.md), so the tab is built with a `TagsLook` value in
`WindowMetrics.Tags.look`: chip style, + field style, how a row on the open scene shows, and when
⌕ shows. `TagsLook.a` is the mockup, `TagsLook.b` the macOS-flavoured alternatives. The render test
(`TagsTabRenders.swift`) sets each in turn and draws the window offscreen. When the owner picks,
phase 2 deletes the enum cases not chosen and the `static var` becomes constants, just as #19's
compact-bar candidates went.

## 5. Testing buttons SwiftUI won't let you click

Offscreen, SwiftUI exposes no accessibility tree, so a test can't find the × or a row's button.
The buttons each call one method of `TagActions`, and the test calls the same method on a
`TagActions` made from the window's own book, page and Search sheet. The + field is an AppKit
`NSTextField`, which the test can find, type into through its field editor, and send `insertNewline:`
as the Return key would. Neither synthesizes input: both call our own code in our own process.

A test has no events, so AppKit's "one undo group per event" never closes a group. Without help,
three actions in a row would be one undo step. `asAnEvent` opens and closes a group around each
action, as an event would.
