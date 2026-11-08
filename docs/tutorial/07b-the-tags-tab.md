# 07b — The Tags tab: a pure sort, undo that inverts exactly, a custom `Layout`, and one shared chip

The Tags tab (PLAN §8.3, issue #20) shows the open scene's tags as chips with a **+ tag** field,
then every tag in the book with how many scenes use it. A click on a row toggles the tag on the
open scene, and a row's ⌕ opens Search on it. This chapter teaches four things a Rust programmer
meets here:
- a sort and a spelling rule as pure functions in core, so they're tested without a window;
- undo inverses that invert exactly their own edit, on another view's undo manager;
- SwiftUI's `Layout` protocol, for chips that wrap;
- one chip view and one typing rule shared by two features, so they can't drift.

## Where the code is

| File | What it holds |
| --- | --- |
| [`BookTags.swift`](../../Sources/SceneItCore/Model/BookTags.swift) | `BookTags` (the list, its sort, the book's spelling) and `SceneTag` (one tag: typed, compared, searched) |
| [`OpenBook.swift`](../../Sources/SceneItCore/Store/OpenBook.swift) | `addTag`, `removeTag`, `toggleTag`, and their undo on the page's manager |
| [`TagWording.swift`](../../Sources/SceneItCore/Window/TagWording.swift) | every string the tab shows, and the undo names |
| [`TagsTab.swift`](../../SceneIt/Window/TagsTab.swift) | the tab, `TagActions` and the + tag field |
| [`TagChip.swift`](../../SceneIt/Window/TagChip.swift) | the chip, shared with File a Copy |
| [`ChipFlow.swift`](../../SceneIt/Window/ChipFlow.swift) | the wrapping layout, shared with File a Copy |

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
key is the usual spelling. Swift's sort doesn't promise stability, so the tie-breaker must decide
every tie. Here it does: two entries never share a key, because case variants were merged into
one entry first.

**Case.** Tags that differ only in case are one tag (the owner, #20). `SceneTag.key` lowercases;
that's exact because the book holds only ASCII (ADR 0028), so there's no Unicode case-folding to
worry about. If the book has both `Mara` and `mara`, the list shows the spelling the most scenes
use, and on a tie the first in code-point order, so `Mara` beats `mara` (and `MARA` beats both).
`BookTags.spelling(of:)` gives a typed tag that spelling, which is how typing `mara` adds `Mara`.

**Typed versus clicked.** Only what's typed goes through `SceneTag.typed`: trimmed, and one
leading `#` dropped, as `book.md` reads a `tags:` item (book format §2.2), so typing `##x` gives the
tag `#x`, the same tag the file would. There's one difference: typing also trims the spaces after
that `#`, so `# x` is `x`, where the file reads ` x`. A row adds the book's tag exactly as it's
spelled, so a tag that really starts with `#` stays that way.

## 2. Undo that inverts exactly its own edit

The owner chose to put tag edits on the scene's **page** undo manager, as comment actions are
(PLAN §8.6). So ⌘Z on the page takes back a tag edit or the typing around it, in the order they
happened. Two private primitives do all of it, and each registers the other as its inverse:
- `takeTags` removes given spellings, each at its recorded index or, if the tags have moved, the
  nearest index that has that spelling;
- `putTags` inserts given spellings at their indices, skipping a spelling the scene already had
  when it began.

Each records what it actually did, and hands only that to its inverse:

```swift
        registerPageUndo(in: scene, named: name) { _ = $0.takeTags(put, from: scene, named: name) }
```

This matters because something outside the page's undo can change the tags between an edit and
its undo: an Errors-tab repair sets a scene's tags from a `tags:` line. Two earlier versions got
this wrong:
- Add's inverse removed the tag in every case, so undoing "Add `storm`" after a repair had also
  added `STORM` lost `STORM`.
- Remove's inverse inserted every spelling it took, unconditionally, so undoing a removal after a
  repair had put the tag back duplicated it. (The version before that refused any spelling the
  scene had in any case, and dropped a case variant taken in the same removal.)

An undo inverts exactly its own edit: it takes only the spellings it put, and puts back only the
spellings it took that the scene hasn't got again. Repeats taken together come back together. The
rules for a new edit (no duplicate in any case) belong to `addTag` and the row's toggle, which
check before calling `putTags`. `removeTag` gathers every case variant and repeat, so one click
turns a row off.

Each inverse changes only the tag list, never the whole scene, so undoing a tag edit can't take
back typing made after it. The inverse registers its own inverse, which is how redo works:
`UndoManager` turns what an undo registers into the redo step. `registerPageUndo` doesn't rename
while undoing or redoing (#125), so Redo reads "Redo Add Tag".

**Focus.** The owner chose to keep the focus where the writer is: Return in the + tag field leaves
it in the field, ready for the next tag, and × and row clicks don't move it at all. ⌘Z goes to the
focused view's undo manager (`UndoRouter`), so in the field it undoes the field's own typing; to
undo a tag, the writer clicks the page first. Every tag edit still calls `breakUndoCoalescing()`
on the page, so typing before and after it stay separate steps rather than one long "Typing".

**Focus.** The owner chose to keep the focus where the writer is: Return in the + tag field leaves
it in the field, ready for the next tag, and × and row clicks don't move it at all. ⌘Z goes to the
focused view's undo manager (`UndoRouter`), so in the field it undoes the field's own typing; to
undo a tag, the writer clicks the page first. Every tag edit still calls `breakUndoCoalescing()`
on the page, so typing before and after it stay separate steps rather than one long "Typing".

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

## 4. One chip, one typing rule

Aesthetic choices are the owner's (CLAUDE.md). Phase 1 kept the candidate looks in one value so a
render test could draw each; the owner mixed them (the accent-tinted chip and the standard rounded
field from one, the tinted bold row and an always-visible ⌕ from the other), and phase 2 deleted
the rest.

File a Copy had its own chip and its own reading of a typed tag, so its tags could differ from the
Tags tab's in case handling and in what a `#` meant. Now `TagChip` draws both, taking its label and
an optional `Removal` (the ×'s wording and action), and `FilingDraft.commitPendingTag` reads what's
typed through `SceneTag.typed` and `SceneTag.contains`. In Rust terms, the two features now call
one function instead of keeping two copies in step.

## 5. Testing buttons SwiftUI won't let you click

Offscreen, SwiftUI exposes no accessibility tree, so a test can't find the × or a row's button.
The buttons each call one method of `TagActions`, and the test calls the same method on a
`TagActions` made from the window's own book, page and Search sheet. The + field is an AppKit
`NSTextField`, which the test can find, type into through its field editor, and send `insertNewline:`
as the Return key would. Neither synthesizes input: both call our own code in our own process.

A test has no events, so AppKit's "one undo group per event" never closes a group. Without help,
three actions in a row would be one undo step. `asAnEvent` opens and closes a group around each
action, as an event would.
