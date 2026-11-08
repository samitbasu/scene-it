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
public func shows(_ part: ChromePart) -> Bool {
    switch part {
    case .rail, .toolbar, .rightPanel, .statusBar: self == .off
    }
}
```

In Rust terms it's a pure `fn shows(&self, part: ChromePart) -> bool` with an exhaustive `match`:
add a `ChromePart` and the compiler finds the arm you forgot. The window then writes
`if chrome.shows(.rail) { IconRail(...) }`. The alternative, "save the panel state, hide it,
restore it later", is a second copy of the state that can drift from the first (what if the writer
presses ⌘] in between?). Here there is nothing to restore.

The state lives in `WindowChrome`, an `@Observable` object the window creates with the book's
window, so a book always opens out of focus mode (the owner's pick).

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

The Esc order (PLAN §8.4, with the page's find bar placed): popovers, then the dialog and sheets,
then the find bar, then focus mode. The order is the order of an enum's cases:

```swift
public enum EscapeLayer: CaseIterable, Hashable, Sendable {
    case popover
    case dialog
    case sheet
    case findBar
    case focusMode
```

and the resolver is a pure function over a snapshot of the window:

```swift
public static func escape(in context: EscapeContext) -> EscapeResult {
    guard let layer = allCases.first(where: { $0.isUp(in: context) }) else { return .passOn }
    return layer.canClose(in: context) ? .close(layer) : .hold(layer)
}
```

`.hold` is the interesting case. While File a Copy's dialog is filing, closing it would throw
away what the writer typed, which a failed filing still needs; so Esc closes nothing, not even
what's under the dialog. Putting the stage *into the resolver's input* (`dialog: FilingStage?`)
is what makes that rule impossible to forget at any one call site. A sheet covers the find bar,
which is why `.sheet` comes before `.findBar`: Esc can't close a find bar the writer can't see.

A test unwinds a window with every layer up, Esc by Esc, and checks the order it closed them in
equals `allCases`. In Rust you'd reach for the same shape: a `#[derive(PartialOrd)]` enum and
`iter().find(...)`.

The window's `WindowKeys` is the only thing that *acts* on the result:

```swift
lastEscape = (entrance, result)
switch result {
case .passOn:
    return .passedOn
case .hold:
    NSSound.beep()
case .close(.popover):
    popover = nil
```

(`lastEscape` records where each Esc came in and what it did, so the tests can prove it was the
resolver, not some other path, that closed a dialog.)

The same goes for File a Copy's dialog: the model is the only authority over it. The sheet is
presented while a draft exists, and the binding SwiftUI is given ignores what SwiftUI writes back
(`set: { _ in }`), so nothing SwiftUI does on its own (a dismissal, a presentation race) can drop
what the writer typed. Only Cancel, Esc through the resolver, and a filed copy end a draft.

Then every place Esc can arrive calls `escape(from:)` (saying where it came in), and only falls back to its own meaning when
told `.passedOn`:

| Where the focus is | How Esc arrives | Fallback |
| --- | --- | --- |
| A sheet, the File a Copy dialog, a palette popover | `EscapeKey`, a hidden `.cancelAction` button (a key equivalent, step 1) | none |
| The page or the notes (`SceneTextView`) | `doCommand(by: cancelOperation:)` | the text view's own Esc |
| The title field, the page's find bar field | the field's delegate, `control(_:textView:doCommandBy:)` | the field's own |
| Comments' search field | `.onKeyPress(.escape)` | the field's own |
| A comment card | `cancelOperation` | ends the edit |
| The Errors tab | `cancelOperation` | focus back to the page |

(The notes' own find bar keeps AppKit's Esc, which closes that bar.)

Why a key equivalent for sheets and popovers? Their focus is often in a SwiftUI `TextField`,
whose field editor would see the key first otherwise; key equivalents run before it (step 1).
Why *not* one for the page? Because it would run first everywhere in the window, including fields
that have their own Esc.

One trap worth knowing: neither `NSTextView` nor `NSResponder` actually *implements*
`cancelOperation:`. Swift lets you write `override func cancelOperation` (the method is declared
in a category), but `super.cancelOperation(sender)` then sends a message nothing answers, and in
this app an Objective-C exception is a crash (ADR 0026). So the text views intercept the command
one level up instead:

```swift
override func doCommand(by selector: Selector) {
    if selector == #selector(NSResponder.cancelOperation(_:)), keys?.escape(from: .focusedView) == .handled { return }
    super.doCommand(by: selector)
}
```

`#selector` names an Objective-C method; `Selector` is a runtime key. Rust has no analogue in safe
code; think of a `&'static str` method name looked up in a vtable at runtime.

**When no view has the focus.** Just after a sheet opens, or after a focused view goes away, the
window itself can be the first responder. Then no view hears Esc, and before this fix nothing did:
the writer could be stuck in focus mode. AppKit hands a key that nothing took along the responder
chain, view, superview, …, window, and on to whatever follows the window. So
`WindowEscapeFallback` puts one small `NSResponder` at the *end* of that chain, whose `keyDown`
asks `escape(from: .window)`. A view that handles Esc never passes the key on, so Esc is never handled twice.
It goes at the end, not straight after the window: the first try put it straight after, and
SwiftUI's own focus and popovers stopped working in the tests, because SwiftUI keeps responders of
its own there. In Rust terms, the chain is a linked list of `&mut dyn Responder`, and we appended
a node instead of splicing one in where SwiftUI expects its own.

**Moving the focus mid-key.** Closing the find bar moves the focus (AppKit gives it to the page),
so `PageFocus.closeFindBar` puts it back. A field's focus is really its *field editor*'s, a shared
`NSTextView`, so the field and its selection are recorded, and the selection is restored after
the field is made first responder again (which by itself selects all its text). In a SwiftUI
`TextField`, doing that *while the field is still handling the key* lost what was typed, so its
`onKeyPress(.escape)` decides now and closes on the next turn (`escapeAfterThisKey`).

The same `doCommand(by:)` hook lets the sheet's focus holder (`UndoFocusView`) handle *no* Tab:
the command goes on up the chain as before, so nothing the sheet covers can take the focus.

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
logic of its own. That only works if each stop's "take the focus" answers truthfully: the Comments
tab makes the field or card first responder itself and returns what `makeFirstResponder` said.

"The search field" is the page's find bar field (⌘F): the Search sheet covers and disables the
page and the panel, so Tab could never move between them and its field.

That field is AppKit's own, made by `NSTextFinder`, and we can't subclass it. Its keys go to its
delegate, which is the find bar's. `DeskView` puts a stand-in delegate in front that handles Tab,
Shift-Tab and Esc, and forwards every other message, the Objective-C way:

```swift
nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
    finderDelegate
}
```

`responds(to:)` says yes for anything the original answers; `forwardingTarget(for:)` sends those
messages on. It's a dynamic proxy, decided per message at runtime: closer to a hand-written
`Deref` to an inner object than to anything Rust's trait system does statically. Those two
overrides are `nonisolated` (they override `NSObject`'s), so the stored delegate they read is
`nonisolated(unsafe)`: safe because AppKit only sends delegate messages on the main thread, the
thread that set it. A test types into the field and presses Return, to prove finding still works
through the stand-in.

## 5. SwiftUI focus and keys

SwiftUI's own focus model is `@FocusState`: a property bound to a view with `.focused(_:)`.
Setting it asks SwiftUI to make that view the first responder, on a later turn, so it can't say
whether it worked. That's why the Comments tab's Tab stop goes to AppKit instead
(`window.makeFirstResponder(field)`), which answers at once.

To catch keys in a SwiftUI `TextField`, `.onKeyPress` runs before the field acts on them and
returns `.handled` or `.ignored`:

```swift
.onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
```

Shift-Tab arrives as the backtab character U+0019, not as Tab with Shift, which is why it's
listed. For AppKit views made through `NSViewRepresentable`, SwiftUI focus doesn't reach in, so
they get `WindowKeys` from the environment (`@Entry var windowKeys`) and call it directly.

## 6. When SwiftUI's modifier isn't enough

In the app's `Window` scene, `.toolbarVisibility(.hidden, for: .windowToolbar)` left the toolbar
showing (a hosted test in the app's own window found it). `FocusModeToolbar` steps down to AppKit:
an `NSViewRepresentable` that sets `window.toolbar?.isVisible`, the same pattern as
`MainWindowCloseButton` (ADR 0038). Its coordinator watches the toolbar with key-value observing
(KVO): `toolbar.observe(\.isVisible)` calls back whenever the property changes, in the same turn,
so a toolbar SwiftUI shows again in focus mode is hidden before anything is drawn. KVO is
Objective-C's built-in observer pattern; Rust has nothing built in, the nearest being a `watch`
channel you'd wire up yourself. It decides once, as focus mode begins, whether the toolbar was
showing, so leaving focus mode never shows a toolbar the writer hid, and `dismantleNSView` shows
it again, so closing a book in focus mode doesn't leave the window without one.

View → Show/Hide Toolbar is macOS's own item, rebuilt in `WindowCommands` (it replaces the
`.toolbar` command group) so that focus mode can disable it, the owner's pick. The View menu reads
the window's `WindowChrome` from `BookController.mainWindowChrome`, not from SwiftUI's focused
values: there's one main window (ADR 0038), and the hosted tests can then check the menu, which
sees no focused window when the test app isn't active.

## Tests

- `Tests/SceneItCoreTests/Window/FocusModeTests.swift`: the chrome, the Esc order (including
  holding while File a Copy files) and the Tab order, as pure functions.
- `SceneItTests/FocusModeWindowTests.swift`: through the window, with keys delivered the way
  `NSApplication` does it, in-process (`performKeyEquivalent` first, then `sendEvent`). The desk's
  frame proves the rail, panel and status bar hide and come back to the pixel; the caret is kept;
  Esc with a palette, a sheet, the dialog (editing and filing) and the find bar; Tab round the
  stops, and nowhere under a sheet.
- `SceneItTests/FocusModeAppWindowTests.swift`: the toolbar in the app's own window, a toolbar the
  writer hid, and Close Book in focus mode.
