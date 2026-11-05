# 07 — Undo: `UndoManager`, text undo versus structural undo

How Scene It undoes things: what an `UndoManager` is, how it groups and coalesces, why the
app has one per scene plus one for the book's structure, and the single rule that decides
which one the toolbar's buttons and Edit → Undo act on. Read it after
[chapter 05](05-appkit-interop-textkit2.md), whose §8 introduced the page's undo manager.

## Where the code is

| File | What it holds |
| --- | --- |
| [`Sources/SceneItCore/Window/UndoRouting.swift`](../../Sources/SceneItCore/Window/UndoRouting.swift) | `UndoFocus` and `UndoStack`: the routing rule, as data |
| [`SceneIt/Window/UndoRouter.swift`](../../SceneIt/Window/UndoRouter.swift) | `UndoRouter`, which applies the rule to a window; `UndoFocusView` |
| [`Sources/SceneItCore/Store/OpenBook.swift`](../../Sources/SceneItCore/Store/OpenBook.swift) | `undo(for:_:)` (`pageUndo`, `notesUndo`), `titleUndo(for:)`, `structureUndo`, `errorsUndo`, `select(_:)` |
| [`SceneIt/Editor/SceneTextEditor.swift`](../../SceneIt/Editor/SceneTextEditor.swift) | hands the page, or the notes, its scene's manager |
| [`SceneIt/Window/WindowToolbar.swift`](../../SceneIt/Window/WindowToolbar.swift) | the Undo and Redo buttons |

The tests: [`SceneItTests/UndoRouterTests.swift`](../../SceneItTests/UndoRouterTests.swift),
the Errors tab case in [`SceneItTests/ErrorsTabTests.swift`](../../SceneItTests/ErrorsTabTests.swift),
and `UndoRoutingTests` in [`Tests/SceneItCoreTests/Window/WindowModelTests.swift`](../../Tests/SceneItCoreTests/Window/WindowModelTests.swift).

---

## 1. Commands versus closures

The textbook Rust design is the *command pattern*: every edit is a value of an enum (or a
`Box<dyn Command>`) with `apply` and `revert`, and the history is a `Vec` of them with a
cursor. Undo calls `revert` on the command under the cursor; redo calls `apply` again. The
command knows both directions up front.

Foundation's `UndoManager` turns that inside out. Nothing is stored about an edit except
**what would undo it**, registered at the moment the edit happens, as a closure:

```swift
        errorsUndo.registerUndo(withTarget: self, handler: inverse)
```

(`OpenBook.commit`, the one place every Errors-tab operation goes through.) When the writer
undoes, the manager runs that closure. The closure makes its change through the same public
methods as any edit, and *those* register their own inverse; because the manager is undoing,
it files that registration on the redo stack instead. So redo is never written separately: it
falls out of each operation registering its inverse. In Rust terms, every `revert` returns
the command that reverts *it*.

Two consequences shape the code:

- **Register the inverse of your own change, not a snapshot.** `deleteError` registers
  `reinsert(entry, at: index, in: owner)`, never "put the scene back as it was", so undoing a
  deletion keeps whatever the writer typed in that scene since (ErrorEntryEditTests,
  `undoingADeleteKeepsWhatWasTypedSince`). A snapshot would silently revert the typing.
- **The target is *not* retained,** unlike an `Rc` captured in the closure: the manager keeps
  a bare pointer to it, and the closure is handed that pointer when it runs. Register against
  an object that outlives the history (the book, which owns the managers), never a throwaway
  one: #118 registered a comment's removal against a fresh `NSObject`, so the action called
  into freed memory on Undo and crashed (#119). `withTarget:` also lets
  `removeAllActions(withTarget:)` find a target's actions.

## 2. Groups

One writer action can register several inverses; Undo should take them all back at once. A
**group** brackets them: `beginUndoGrouping()` … `endUndoGrouping()`. Undo runs a group's
actions in reverse order of registration, which is why a paste that brings comments registers
the comments' removal *first* ([chapter 05](05-appkit-interop-textkit2.md) §8).

**Comment actions** (PLAN §8.1, #23) lean on that order too. A comment is two things that must
agree: an id on the runs it covers, and an entry in the scene's `comments`. Whatever changes the
page's *text* goes through the page's own text view (`SceneTextEditor.newComment`, `dismiss`,
`reanchor`, which rewrite the runs' attributes as formatting does), so the page's undo history
keeps describing its storage; whatever changes only the *list* is an `OpenBook` method
(`setText(_:ofComment:in:)`, `recolor`, `dismiss`, `removeComments`) that registers its own
inverse on the same page history. Within one group:

| Action | Registered, in order | Undo runs | So that |
| --- | --- | --- | --- |
| New comment | remove the comment; the text's id | the text's id goes, then the comment | no run ever names a missing comment |
| Dismiss | the text's id off; restore the comment | the comment comes back, then the id | the same, the other way round |

`removeComments` puts a comment back at its old index, so the panel's order survives an undo.

Edit → New Comment is enabled only when there's a selection a comment can cover (ADR 0037). A
SwiftUI menu item re-evaluates `.disabled(...)` only when observed state changes, so the page
computes that on each selection change and hands it to `EditorFormatting` with the selection's
formats (`Active.comments`), the same observable value the Format menu reads.

With `groupsByEvent` (on by default), the manager opens a group at the first registration in
an event and closes it when the run loop finishes that event. So one Delete click is one
group, with no code at all. Tests have no events: a registration leaves `groupingLevel == 1`
even after the test sleeps for 50 ms (observed in this repo's probe). `undo()` closes an open
top-level group before undoing, so the router's `undo()` works in tests and in the app alike.

**Action names.** `setActionName(_:)` names the open group; `undoMenuItemTitle` then reads
"Undo Delete Entry". The Errors tab names its two operations:

```swift
        commit(ref.owner, part.with(errors: errors)) { $0.reinsert(ref.entry, at: ref.index, in: ref.owner) }
        errorsUndo.setActionName(ErrorsWording.deleteUndoName)
```

## 3. Coalescing

`NSTextView` doesn't open a group per keystroke. While the writer types, it keeps one
"typing" group open and adds to it, so Undo takes back a run of typing, not a letter. That's
*coalescing*, and the group is named "Typing" (hence the toolbar's "Undo Typing" tooltip).
It ends when the selection moves, or when code calls `breakUndoCoalescing()`. The page calls
it before a paste and before loading another scene, so neither joins the typing before it.

## 4. Whose history? Five kinds

PLAN §8.6, and the owner's decision for the Errors tab:

| What | Manager | Kept |
| --- | --- | --- |
| A scene's page text (and comments, which register there) | `OpenBook.pageUndo(for:)`, one per scene | for the session |
| A scene's title | `OpenBook.titleUndo(for:)`, one per scene | for the session |
| A scene's notes (comments never reach them, ADR 0035) | `OpenBook.notesUndo(for:)`, one per scene | for the session |
| The book's structure: scenes added, moved, cut (#28) | `OpenBook.structureUndo` | for the session |
| The Errors tab's Delete and Fix | `OpenBook.errorsUndo` | for the session |

The page's text view asks its delegate for a manager, and the delegate answers with the open
scene's. The notes' text view has a delegate of the same class (`SceneTextEditor`, chapter 05
§11), made for the other part of the scene, so the same line answers with the notes' history:

```swift
    func undoManager(for view: NSTextView) -> UndoManager? {
        scene.map { book.undo(for: $0, part) }
    }
```

`OpenBook` keeps one dictionary of text histories, keyed by part and then by scene, so "the
page's" and "the notes'" are the same code with a different key. Typing in the notes never
lands on the page's history, and an undo on the page never takes back a note. Each part's
history is cleared on its own when that part is replaced from elsewhere (`replaceBody`,
`replaceNotes`, an Errors-tab fix that changed it), since a history only fits the text it was
recorded against.

**The notes need nothing from the router.** `UndoRouter` already sends Undo to "the focused
text view's own manager" (section 5), and asks AppKit for it: `firstResponder.undoManager`,
which for a text view is whatever its delegate returns. So once the notes' view existed with
the right delegate, Cmd+Z and the toolbar's buttons went to the notes' history whenever the
notes had the focus, without a new case in `UndoStack`. That's the payoff of encoding the rule
as "whatever is focused" rather than as a list of editors.

The title's field editor is a small `NSTextView` subclass whose `undoManager` is the open
scene's title history (`TitleField.Editor` in `EditorArea.swift`).

Why so many? A per-scene history means switching scenes never makes Undo reach into a scene
the writer can't see. The Errors tab's entries sit outside the page text and can belong to any
scene, and the page's history is cleared whenever its text is replaced from elsewhere, so they
can't live there. And they aren't structure either: an undo from the Scenes sheet should only
ever take back something the sheet shows.

**Leaving a scene.** Every way of opening a scene goes through `OpenBook.select(_:)`, which
posts `openBookWillSwitchScene` *before* the open scene changes. The page, the notes and the
title field all listen: the title ends its editing, so what was typed stays in the scene it was typed
in, and the page and the notes end their typing groups. (Their text has already reached the
model: every keystroke is synced in the turn it's typed.) Without that step, the title's field editor kept the
old scene's text while the field moved on to the next scene, and the next keystroke wrote the
old title into the new scene.

## 5. The routing rule, encoded once

Two things must agree on which manager is current: the toolbar's buttons and Edit → Undo
(with Cmd+Z), including whether they're enabled and what they're called. So the rule is a
pure function of two inputs, in the core:

```swift
    /// While the Scenes sheet is open, the structure; otherwise what has the focus decides.
    public init(mode: WindowMode, focus: UndoFocus) {
        if mode == .scenes {
            self = .structure
            return
        }
        switch focus {
        case .text: self = .focusedText
        case .errorsTab: self = .errors
        case .elsewhere: self = .none
        }
    }
```

`UndoStack.focusedText` means "the focused text view's own manager": the page's, the
title's, the notes', or a field's. The function is tested for every mode and focus
(`UndoRoutingTests`).

**The Errors tab.** Clicking a button doesn't move the keyboard focus, so after a Delete the
page would keep it and Cmd+Z would undo typing. The tab therefore *takes* the focus when the
writer deletes or fixes an entry, and keeps it, with a ring around the list so it's clear that
typing won't reach the page. Esc, or a click in the page, goes back. That's the rule the
writer sees: Undo acts on what you last worked in.

## 6. Applying the rule: `UndoRouter`

`UndoRouter` (one per book window) turns the rule into a manager:

```swift
    /// The undo manager Undo and Redo act on now, if any.
    var manager: UndoManager? {
        switch stack {
        case .focusedText: window?.firstResponder?.undoManager
        case .structure: book.structureUndo
        case .errors: book.errorsUndo
        case .none: nil
        }
    }
```

The window's mode reaches it from `BookWindow` (`.onChange(of: mode, initial: true)`), and the
focus is read from the window's first responder: any `NSText` (a text view or a field editor)
is `.text`; an `UndoFocusView` (the sheets, the Errors tab) says what it is.

**Both the toolbar and the Edit menu call it.** AppKit's own Edit → Undo sends `undo:` down
the responder chain, and `NSWindow` answers it with the first responder's `undoManager`.
(Checked: `NSTextView`, `NSView`, `NSResponder` and `NSApplication` don't respond to `undo:`;
`NSWindow` does.) That path doesn't agree with the rule everywhere. With nothing focused, it
reaches the window's own manager, where SwiftUI and the title's old field editor registered
things the toolbar doesn't show. So the app replaces the menu's group:

```swift
        CommandGroup(replacing: .undoRedo) {
            Button(router?.state.undo ?? WindowWording.undo) { router?.undo() }
                .keyboardShortcut("z")
                .disabled(router?.state.undo == nil)
```

The router reaches the commands as a focused value of the key window (`\.undoRouter`).
`UndoFocusView` still answers `undoManager` with the router's choice, for anything else in
AppKit that asks the focused view.

**Read-only books** have nothing to undo: the state is empty, and `undo()` does nothing, while
`book.isEditable` is false. An undo there would change text the book can't keep.

**Keeping the state current.** The router listens to the routed manager only (group closed,
undo, redo, checkpoint), with `queue: nil`, so the notification is delivered in the same turn
it's posted and the state is right as soon as an undo finishes. `undo()` and `redo()` also
refresh it themselves. Two changes come without a notification: `removeAllActions()` (the page
clears a scene's history when its text is replaced) and a change of focus. A KVO observer on
`NSWindow.firstResponder` saw nothing when `makeFirstResponder` changed it here, so the router
also refreshes on `NSWindow.didUpdateNotification`, which AppKit posts after every event the
window handles. The tests, which have no events, call `window.update()` after moving the
focus, as AppKit would.

**Lifetimes.** Every observer captures the router `weak`, and the router holds the window and
the observed manager `weak` too. It removes the manager's observers whenever it switches
managers, and both sets in its `isolated deinit`. Because `didUpdateNotification` runs the router
after nearly every event, a crash anywhere in Swift concurrency tends to show up here first. The
crash in #120 (`swift_task_isMainExecutor` under `UndoRouter.observe`) wasn't the router's
fault: an Objective-C exception had unwound a task a moment earlier ([chapter 5
§10](05-appkit-interop-textkit2.md), ADR 0026).

**A test quirk.** With `groupsByEvent`, a group opened outside an event never closes in a
test, and the window won't validate Edit → Undo for an open group. The router's `undo()`
calls `UndoManager.undo()`, which closes it first, so the tests drive the router directly.

## 7. Rust comparison, summed up

| | Rust command pattern | `UndoManager` |
| --- | --- | --- |
| An edit is stored as | a command value with `apply`/`revert` | the closure that undoes it |
| Redo | `apply` again | the undo closure's own registration, filed on the redo stack |
| Grouping | a `Vec<Command>` command | `begin`/`endUndoGrouping`, or one group per event |
| Coalescing | merge into the last command | the text view keeps its typing group open |
| Which history | the caller passes it | AppKit: the first responder's `undoManager`; here, the router's rule |
