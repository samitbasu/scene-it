# 0036 — No drag and drop of text

**Status:** Accepted (2026-11-04, the owner's call on #92). Amends [0016](0016-text-only-no-images.md) and
[0028](0028-strict-ascii-no-input-methods.md) where they mention dropped content: nothing is dropped.

## Context
The page refused every drop by accident (#92): `SceneTextView` named its readable types by their UTIs, and
`NSTextView`'s inherited `acceptableDragTypes` named them by their legacy names, so the two lists had nothing in
common. Making drops work as pastes (with moves within the page) turned out to need a drop path of our own, because
`NSTextView`'s own crashed on a move with our undo grouping (`_setGroupIdentifier:` with no open group). The owner
decided text doesn't need drag and drop at all.

## Decision
- **No drops** onto the page, the notes, the title field's editor or File a Copy's tag field and note: no text,
  images or files, from this app or any other. Text arrives by typing or pasting, and pasting is the one path that
  applies the character policy, the codec and the page clip's comments.
- **No dragging text out** of them either: a press on the selection followed by a drag doesn't start a drag
  session, so the system's drop caret never shows.
- The rule lives in `KeyboardTextView`, which every one of those editors is: `acceptableDragTypes` is empty, the view
  registers no drag types, `draggingEntered`/`draggingUpdated` answer no operation and `performDragOperation` does
  nothing. Dragging out is refused at both of `NSTextView`'s starting points. One is
  `dragSelection(with:offset:slideBack:)`, reached from `mouseDown`: before macOS 27 that's every editor, and from
  macOS 27 it's any text view that overrides `mouseDown`, as the page does for comment clicks (ADR 0035), which then
  has no `NSTextSelectionManager` (observed). The other, from macOS 27, is
  `selectionManager(_:makeDraggingSession:)`, which the notes and the fields answer as their own selection
  manager's delegate; it returns `nil`, documented as "prevent dragging".
- **The comments panel (#25)**: its comment text fields refuse drag and drop the same way (make them
  `KeyboardTextView`s, or apply the same overrides).
- Fields that aren't manuscript text (the Errors tab's fix field, search, the sheets' other fields) keep the system's
  behaviour.

## Rejected
- **Drops as pastes, with moves within the page** (the first version of PR #110): it worked and was tested, but it
  needed its own move and undo grouping in place of `NSTextView`'s, as more code to keep in step with paste.

## Consequences
- **Verified (tests, at the method level):** both of `NSTextView`'s starting points for a drag of the selection refuse
  it, the selection is left as it was, and every drop is refused through the destination entry points.
- **Not verified:** what a real press and drag on the selection does once the drag is refused. Agents don't
  synthesize input, so no test can make one. Most likely it does nothing while the pointer moves, on both the macOS 26
  and the macOS 27 paths, and the release may collapse the selection to a caret. It probably won't start a new
  selection. The owner checks this by hand: select a word, press on it and drag, then release.
- `NSTextView`'s `_setGroupIdentifier:` drop path can't be reached, since `performDragOperation` never calls `super`.

## Learning notes
- A drag reaches a view through `NSDraggingDestination`: `draggingEntered` and `draggingUpdated` answer which
  operation a drop would be (none means refused, and no drop caret), then `performDragOperation` does it. A window
  routes a drag only to views registered for one of its types (`registerForDraggedTypes`), which `NSTextView` does
  from `acceptableDragTypes` in `updateDragTypeRegistration`.
- `@objc(selector:)` on a Swift method replaces the Objective-C method of that selector, even one the superclass
  implements without declaring it in its header. That's how a subclass answers a delegate call that `NSTextView`
  makes to itself. It's a sharp tool: there's no `super` to call, and Swift can't check that the selector matches.
