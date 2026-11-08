# 07c — Focus mode, Esc and Tab: one order, many entrances

Issue #21 (PLAN §4.6, §8.4). Focus mode hides the chrome around the page; Esc closes things in a
fixed order; Tab moves between the page, the right panel and the search field. The Swift and
macOS lessons: how keys travel through AppKit's responder chain, where SwiftUI's focus fits in,
and how to keep a policy that a dozen views consume in exactly one place.

Files: [`Sources/SceneItCore/Window/FocusMode.swift`](../../Sources/SceneItCore/Window/FocusMode.swift),
[`Sources/SceneItCore/Window/WindowKeyOrder.swift`](../../Sources/SceneItCore/Window/WindowKeyOrder.swift),
[`SceneIt/Window/WindowKeys.swift`](../../SceneIt/Window/WindowKeys.swift),
[`SceneIt/Window/WindowChrome.swift`](../../SceneIt/Window/WindowChrome.swift),
[`SceneIt/Editor/SceneTextView.swift`](../../SceneIt/Editor/SceneTextView.swift),
[`SceneIt/Editor/DeskView.swift`](../../SceneIt/Editor/DeskView.swift).

## 1. Focus mode is state, not a preference

The invariant that makes "leaving restores exactly the chrome you had" free: focus mode never
*changes* the chrome's state. The right panel's open/closed preference, the open sheet, the
selected tab: none is touched. Focus mode is a second input to the views, and each view asks
one question:

```swift
public func shows(_ part: ChromePart, under rules: FocusModeRules) -> Bool {
    switch (self, part) {
    case (.off, _): true
    case (.on, .formattingBar): rules.formattingBar == .shown
    case (.on, .rail), (.on, .toolbar), (.on, .rightPanel), (.on, .statusBar): false
    }
}
```

In Rust terms it's a pure `fn shows(&self, part: ChromePart, rules: &Rules) -> bool` with an
exhaustive `match`; add a `ChromePart` and the compiler finds every arm you forgot. The window
then writes `if chrome.shows(.rail) { IconRail(...) }`. The alternative, "save the panel state,
hide it, restore it later", is a second copy of the state that can drift from the first (what if
the writer presses ⌘] in between?). Here there is nothing to restore.

`FocusModeRules` holds the answers PLAN leaves open (does the formatting bar hide? does
opening a scene leave focus mode?) as enums, one field each, with `recommended` as the shipped
value. A test can build a window with any other value, so each switch is exercised.

## 2. How a key reaches your code on macOS

Unlike a browser, AppKit has no single "keydown" listener. When you press a key,
`NSApplication.sendEvent` does, roughly:

1. **Key equivalents.** The key window's `performKeyEquivalent(with:)` walks its views; menus get
   a turn too. SwiftUI's `.keyboardShortcut(.cancelAction)` (Esc) and `.defaultAction` (Return)
   buttons live here. This happens *before* the focused view sees the key.
2. **The first responder.** If nothing took it, the window sends `keyDown` to its first
   responder, the focused view. A text view runs `interpretKeyEvents`, which turns Esc into the
   *command* `cancelOperation:` and Tab into `insertTab:`, and dispatches the command through
   `doCommand(by:)`.
3. **The responder chain.** A command no one implements travels `nextResponder` by
   `nextResponder` (view, superview, …, window) until something responds, or AppKit beeps.

Menus are outside all of this: while a menu is open, AppKit's menu tracking loop owns the
keyboard, so Esc closes the menu and none of our code runs. That's why the resolver below has no
`menu` case, yet menus still come first.

## 3. One resolver, every entrance

PLAN's Esc order: menus and popovers, then sheets, then focus mode. The order is data, the order
of an enum's cases:

```swift
public enum EscapeLayer: CaseIterable, Hashable, Sendable {
    case popover
    case dialog
    case sheet
    case focusMode

    public static func closedByEscape(in context: EscapeContext) -> EscapeLayer? {
        allCases.first { $0.isUp(in: context) }
    }
```

`closedByEscape` is a pure function, tested without a window. A test even unwinds a window with
every layer up, Esc by Esc, and checks the order it closed them in equals `allCases`.

The window's `WindowKeys` is the only thing that *acts* on it:

```swift
func escape() -> EscapeOutcome {
    guard let layer = EscapeLayer.closedByEscape(in: escapeContext) else { return .passedOn }
    switch layer {
    case .popover: popover = nil
    case .dialog: filing.cancel()
    case .sheet: mode.wrappedValue = mode.wrappedValue.closingSheet
    case .focusMode: chrome.set(.off)
    }
    return .handled
}
```

Then every place Esc can arrive calls `escape()`, and only falls back to its own meaning when
told `.passedOn`:

| Where the focus is | How Esc arrives | Fallback |
| --- | --- | --- |
| A sheet, the File a Copy dialog, a palette popover | `EscapeKey`, a hidden `.cancelAction` button (a key equivalent, step 1) | none |
| The page or the notes (`SceneTextView`) | `doCommand(by: cancelOperation:)` | the text view's own Esc |
| The title field | its delegate's `control(_:textView:doCommandBy:)` | the field's own |
| A comment card | `cancelOperation` | ends the edit |
| The Errors tab | `cancelOperation` | focus back to the page |

Why a key equivalent for sheets and popovers? Their focus is often in a SwiftUI `TextField`,
whose field editor would see the key first otherwise; key equivalents run before it (step 1).
Why *not* one for focus mode? Because it would also run first in the page's find bar, and Esc
there should close the find bar, which AppKit does in the bar's own field. Step 2 gives the find
bar its turn.

One trap worth knowing: neither `NSTextView` nor `NSResponder` actually *implements*
`cancelOperation:`. Swift lets you write `override func cancelOperation` (the method is declared
in a category), but `super.cancelOperation(sender)` then sends a message nothing answers, and in
this app an Objective-C exception is a crash (ADR 0026). So the text views intercept the command
one level up instead:

```swift
override func doCommand(by selector: Selector) {
    if selector == #selector(NSResponder.cancelOperation(_:)), keys?.escape() == .handled { return }
    super.doCommand(by: selector)
}
```

`#selector` names an Objective-C method; `Selector` is a runtime string-like key. Rust has no
analogue in safe code; think of a `&'static str` method name looked up in a vtable at runtime.

## 4. Tab: the same pattern

```swift
public func following(_ direction: TabDirection) -> [TabStop] {
    let all = Self.allCases
    let ordered = direction == .forward ? all : all.reversed()
    guard let index = ordered.firstIndex(of: self) else { return [] }
    return Array(ordered[(index + 1)...] + ordered[..<index])
}
```

`WindowKeys.tab` tries those stops in turn and stops at the first that takes the focus
(`stop.following(direction).contains { focus($0) }`: `contains` short-circuits, like Rust's
`Iterator::any`). A hidden panel or a closed find bar simply refuses, so focus mode needs no Tab
logic of its own.

"The search field" is the page's find bar field (⌘F): the Search sheet covers and disables the
page and the panel, so Tab could never move between them and its field.

That field is AppKit's own, made by `NSTextFinder`, and we can't subclass it. Its Tab goes to its
delegate, which is the find bar's. `DeskView` puts a stand-in delegate in front that handles Tab
and Shift-Tab and forwards every other message, the Objective-C way:

```swift
override func forwardingTarget(for selector: Selector!) -> Any? {
    finderDelegate
}
```

`responds(to:)` says yes for anything the original answers; `forwardingTarget(for:)` sends those
messages on. It's a dynamic proxy, decided per message at runtime: closer to a hand-written
`Deref` to an inner object than to anything Rust's trait system does statically.

## 5. SwiftUI focus

SwiftUI's own focus model is `@FocusState`: a property bound to a view with `.focused(_:)`.
Setting it to `true` asks SwiftUI to make that view the first responder, on a later turn. The
Comments tab registers that as its "take the focus" action:

```swift
.onAppear {
    keys?.setPanelFocus(for: .comments) { [book, editors, $searchFocused] in
        Self.takeFocus(book: book, editors: editors, search: $searchFocused)
    }
}
```

`$searchFocused` is a `FocusState<Bool>.Binding`, a handle you can capture and set later, much like
capturing a `Binding`. The capture list `[book, editors, $searchFocused]` copies those values into
the closure, the same idea as Rust's `move` closure over clones.

To catch Tab in that SwiftUI field, `.onKeyPress(keys: [.tab])` runs before the field acts on it
and returns `.handled` or `.ignored`. For AppKit views made through `NSViewRepresentable`,
SwiftUI focus doesn't reach in, so they get `WindowKeys` from the environment
(`@Entry var windowKeys`) and call it directly.

## 6. When SwiftUI's modifier isn't enough

`.toolbarVisibility(.hidden, for: .windowToolbar)` left the toolbar showing in our hosted test
windows. Rather than accept a difference between tests and the app, `WindowToolbarVisibility` is a
tiny `NSViewRepresentable` that reaches `view.window?.toolbar` and sets `isVisible`: the same
"step down to AppKit" pattern as `MainWindowCloseButton` (ADR 0038).

## Tests

- `Tests/SceneItCoreTests/Window/FocusModeTests.swift`: the rules, the Esc order and the Tab
  order as pure functions.
- `SceneItTests/FocusModeWindowTests.swift`: through the window. The desk's frame proves the rail,
  panel and status bar hide and come back to the pixel; the toolbar's `isVisible`; the caret kept;
  Esc with a palette, a sheet and the dialog up; Tab round the stops. Keys are delivered the way
  `NSApplication` does it, in-process: `performKeyEquivalent` first, then `sendEvent`.
