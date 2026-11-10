# 07a — The comments panel: SwiftUI over AppKit, a real `NSMenu`, and buttons over text

The Comments tab (PLAN §8.1, issue #25) lists the open scene's comments as cards. Each card's
text is edited in place, and its ⋯ menu recolors or dismisses the comment. A 💬 Comment button
floats below a selection on the page. This chapter teaches five things a Rust programmer meets
here:
- pure core types that the views only show;
- an AppKit text view inside SwiftUI that keeps the model as the truth;
- an `NSMenu` built per click, and why its actions wait until it closes;
- making an AppKit view win the click over the text view it sits on;
- `#selector` meeting a method `NSObject` already has.

## Where the code is

| File | What it holds |
| --- | --- |
| [`CommentQuery.swift`](../../Sources/SceneItCore/Window/CommentQuery.swift) | the search field's parser: words and `#color` tokens |
| [`CommentCards.swift`](../../Sources/SceneItCore/Window/CommentCards.swift) | a scene's cards, in text order, then the detached ones |
| [`WrittenText.swift`](../../Sources/SceneItCore/Text/WrittenText.swift) | where each comment is in the plain text, shared with `book.md`'s serializer |
| [`CommentSelection.swift`](../../Sources/SceneItCore/Window/CommentSelection.swift) | the selected comment, and whether its card is to take the focus |
| [`CommentsTab.swift`](../../SceneIt/Window/CommentsTab.swift) | the tab, the cards and the card's text view |
| [`CommentMenu.swift`](../../SceneIt/Window/CommentMenu.swift) | the ⋯ menu and its control |
| [`CommentButton.swift`](../../SceneIt/Editor/CommentButton.swift) | the floating Comment button |

The tests are in [`CommentPanelTests.swift`](../../Tests/SceneItCoreTests/Window/CommentPanelTests.swift)
(core) and [`CommentsPanelTests.swift`](../../SceneItTests/CommentsPanelTests.swift) (the real window).

## 1. Decide in core, show in the app

Everything the panel decides is a pure value in core, tested without a window. `CommentCards`
orders the cards and quotes their text. It doesn't find the comments' text itself: it asks
`WrittenText`, the same type `book.md`'s serializer writes ranges from, and `BookScene.isDetached`.
An earlier version walked the runs on its own. It disagreed with the serializer about a comment
that spans an empty paragraph, which is what a second implementation of the same rule always
ends up doing (CLAUDE.md, "DRY").

```swift
        let body = WrittenText(scene.body)
        let ranges = body.commentRanges()
```

The search does the same with palette names: `#Red` and a `red` in `book.md` go through one
`PaletteColor(named:)`, which lowercases ASCII only. Lowercasing with Unicode rules first would
turn the Kelvin sign `K` into `k`, so the search would accept `#blacK` where the file
rejects it.

## 2. An AppKit text view in SwiftUI, with the model as the truth

A card's text is a `CommentTextView`, an `AdmittingTextView`, so it has no input method and no
drag and drop (ADRs 0028 and 0036), wrapped in an `NSViewRepresentable`. SwiftUI calls
`updateNSView` with the model's text, and the view shows it unless an edit is under way. Two
details matter:

- **SwiftUI compares inputs, not the view.** If an undo brings back exactly the text SwiftUI last
  passed in, SwiftUI sees no change and skips `updateNSView`, while the view still shows the
  draft. The coordinator therefore re-reads the model on every undo and redo, as the title field
  does.
- **Typing is saved as it happens.** Each change goes to the model with no undo step, and leaving
  the card makes the whole edit one step ([chapter 07](07-undo.md) §2). A sheet opening over the
  panel makes the card read-only mid-edit; the card then gives up the focus first, which commits
  the edit, and shows the model's text, exactly as the title field does.

The card measures itself in `sizeThatFits(_:nsView:context:)`, which takes SwiftUI's
`ProposedViewSize`. That is a typed width rather than a bare `CGFloat` (CLAUDE.md, "no naked
floats").

## 3. A real `NSMenu`, built per click

The owner chose a standard pull-down menu for ⋯. A SwiftUI `Menu` can't put a colored line
after each color's name, so the control is an `NSButton` that builds an `NSMenu` when it's
pressed, from the model as it is at that moment, and pops it up right-aligned under itself.
Each item's target is a small handler object that holds a closure. An item holds its target
weakly, so the handler is also stored in the item's `representedObject`, which the item holds
strongly.

`popUp(positioning:at:in:)` runs a modal tracking loop of its own. An item's action normally
runs inside that loop. A model change made there reached the window only after a later change,
so a recolor showed only once the focus left the card (the owner's bug A). So while the menu is
open, its items only record which one was chosen, and the control runs that item's action once
`popUp` returns, the way a button runs its action after its click:

```swift
            menu.popUp(positioning: nil, at: menuOrigin(menu), in: self)
            highlight(false)
            runChosen()
```

The control also sets `refusesFirstResponder`, so tabbing or a click never moves the keyboard
focus off the page. Otherwise Re-anchor to Selection, which needs the page's selection, would
always be disabled.

## 4. A button over a text view

The floating Comment button is a subview of the page's text view. A text view wants every click
and sets the I-beam pointer as the mouse moves, so a plain subview loses both:
- **The click:** the first version was a SwiftUI button in a hosting view. Part of its frame
  wasn't hit-testable, so a click there went to the text view, which collapsed the selection and
  hid the button before its action ran (the owner's bug B).
- **The pointer:** the I-beam showed over the button.

The fix has three parts:
- **Hit-testing:** the page overrides `hitTest(_:)` to return the button for any point in its
  frame, before the text gets a chance.
- **The cursor:** the button has a cursor rect and a `.cursorUpdate` tracking area that show the
  pointing hand. The page's `mouseMoved`/`cursorUpdate` defer to it.
- **The first click:** `acceptsFirstMouse` returns `true`, so the button works even when the
  window isn't key.

As an `NSButton` it also has `performClick(_:)`, so a test can press it the way AppKit does,
with no synthesized event.

## 5. `#selector` and a method `NSObject` already has

The menu item handler first had `@objc func perform(_:)`. `NSObject` already has `perform(_:)`,
which is `performSelector:` in Objective-C, and `#selector(Handler.perform(_:))` resolved to that
method. Choosing an item then sent the menu item itself as a selector. That raised "unrecognized
selector", and the `UnwoundJobTrap` (ADR 0026) stopped the app. The method is now `run(_:)`. In
Rust a name clash like this is a compile error. In Swift, `#selector` picks whichever
Objective-C method the name resolves to, so names that `NSObject` already uses are best avoided.
