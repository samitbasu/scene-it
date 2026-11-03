# 05 — AppKit interop and TextKit 2

How the page works: an AppKit `NSTextView`, running TextKit 2, hosted inside the SwiftUI
window, kept in step with the model on every keystroke, and guarding what the writer types and
pastes. Read it after [chapter 04](04-swiftui-and-observation.md) (SwiftUI and `OpenBook`); it
leans on [chapter 06](06-attributed-strings.md) for the `RunCodec`, so skim that first if
attributed strings are new to you.

## Where the code is

| File | What it holds |
| --- | --- |
| [`SceneIt/Editor/PageView.swift`](../../SceneIt/Editor/PageView.swift) | the `NSViewRepresentable` that puts the page in SwiftUI, and `PageFocus` |
| [`SceneIt/Editor/ManuscriptTextView.swift`](../../SceneIt/Editor/ManuscriptTextView.swift) | the `NSTextView` subclass: TextKit 2, the page on the desk, keys, the pasteboard |
| [`SceneIt/Editor/PageEditor.swift`](../../SceneIt/Editor/PageEditor.swift) | the coordinator: delegates, model sync, paste, undo managers |
| [`SceneIt/Window/EditorArea.swift`](../../SceneIt/Window/EditorArea.swift) | the title field above the page (decision 0015) |
| [`Sources/SceneItCore/Text/BodyChange.swift`](../../Sources/SceneItCore/Text/BodyChange.swift) | an edit as "these paragraphs replace those", found from the edited range |
| [`Sources/SceneItCore/Text/PageClip.swift`](../../Sources/SceneItCore/Text/PageClip.swift) | the app's own pasteboard data (decision 0017) |
| [`Sources/SceneItCore/Store/OpenBook.swift`](../../Sources/SceneItCore/Store/OpenBook.swift) | `apply(_:to:adding:)`, `pageUndo(for:)`, `resolve(_:into:)` |

The tests: [`SceneItTests/PageTests.swift`](../../SceneItTests/PageTests.swift) drives the real
page in an offscreen window; [`Tests/SceneItCoreTests/Text/BodyChangeTests.swift`](../../Tests/SceneItCoreTests/Text/BodyChangeTests.swift)
and [`Tests/SceneItCoreTests/Store/PageEditTests.swift`](../../Tests/SceneItCoreTests/Store/PageEditTests.swift)
cover the pure parts.

---

## 1. Why AppKit, inside SwiftUI

SwiftUI's `TextEditor` edits a `String` (or, lately, an `AttributedString`) through a binding.
That is enough for a notes field and nowhere near enough for a manuscript: there is no veto on
an edit before it happens, no say over what a paste brings in, no custom pasteboard type, no
per-scene undo manager, no find bar. AppKit's `NSTextView` has all of those, as delegate
methods and overridable hooks. So the page is an `NSTextView`, and SwiftUI hosts it.

The bridge is `NSViewRepresentable`, a protocol whose conforming *value* describes an AppKit
view. SwiftUI calls three methods on it:

| Method | When | Rust analogy |
| --- | --- | --- |
| `makeCoordinator()` | once, before the view exists | constructing the long-lived state behind a widget |
| `makeNSView(context:)` | once: build the `NSView` | `fn new() -> Widget` |
| `updateNSView(_:context:)` | every time the representable's inputs change | a `fn update(&mut self, props)` that diffs |

```swift
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(WindowMetrics.deskColor)
        scrollView.findBarPosition = .aboveContent
        let page = ManuscriptTextView.page()
        page.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = page
        context.coordinator.attach(page)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let editable = book.isEditable && context.environment.isEnabled
        context.coordinator.show(scene, editable ? .editable : .readOnly)
    }
```

The struct itself is thrown away and rebuilt on every SwiftUI update, like any SwiftUI view
(chapter 04). The **coordinator** is what survives: SwiftUI keeps the object `makeCoordinator`
returned for as long as the view stays in the hierarchy, and hands it back in `context`. It's
the natural delegate for the AppKit view, because delegates must be objects that live as long
as the view does. Ours is `PageEditor`.

`context.environment.isEnabled` is how SwiftUI's `.disabled(true)` reaches AppKit. When a rail
sheet covers the page, `BookWindow` disables everything under it, and the coordinator turns
that into `isEditable = false` (and gives up the focus), which is what the sheet-focus test
checks.

**How updates are triggered.** `EditorArea` passes the scene's body to the representable:

```swift
                PageView(book: book, scene: scene.id, paragraphs: scene.body, focus: focus)
```

The page never uses that value; it reads the model itself. It's there so the representable's
inputs change whenever the body does, which is what makes SwiftUI call `updateNSView`. The
coordinator then decides whether anything needs doing (§4).

## 2. `NSTextView` with TextKit 2, not TextKit 1

An `NSTextView` is the visible end of a small object graph. With TextKit 2 it is:

```
NSTextView ─ NSTextLayoutManager ─ NSTextContentStorage ─ NSTextStorage
  (view)      (lays out fragments)   (paragraphs, ranges)   (the attributed text)
```

TextKit 1, the older engine, has an `NSLayoutManager` in the middle instead. The text storage
is the same `NSTextStorage` in both: an `NSMutableAttributedString` subclass, so everything in
chapter 06 applies to it directly.

PLAN §2 settles on TextKit 2 (faster with long text, and what Apple develops). The trap is that
**TextKit 1 is one property access away.** An `NSTextView` built for TextKit 2 quietly rebuilds
itself on TextKit 1 the first time anything reads its TextKit 1 layout-manager property. This
was checked on this toolchain:

```
before: textLayoutManager true
after touching layoutManager: textLayoutManager false
```

There is no error and no log line; the text view just gets slower and loses TextKit 2
behaviour. So `scripts/check.sh` greps every Swift file for that property's name and for
`NSLayoutManager`, and fails the gate if either appears (`forbid_textkit1` in
`scripts/guards.sh`). The page is created explicitly on TextKit 2, which documents the choice
even though it's also the default:

```swift
        let view = ManuscriptTextView(usingTextLayoutManager: true)
```

`init(usingTextLayoutManager:)` is a *convenience* initializer of `NSTextView`. A Swift subclass
inherits its superclass's convenience initializers only if it inherits all the designated
ones, which `ManuscriptTextView` does by declaring no initializer of its own (its stored
properties have defaults). That's why the configuration lives in a `static func page()`
factory rather than an `init`.

## 3. The page on the desk, in one view

PLAN §4.3 wants a white 8.5 × 11 in page with 1 in margins on a gray desk that scrolls. The
page could have been three views (desk, sheet, text view). It's one: the text view is as wide
as the scroll view, paints the desk and the sheet in `drawBackground(in:)`, and uses
`textContainerInset` to put the text column on the sheet:

```swift
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let page = pageRect
        let inset = NSSize(
            width: page.minX + WindowMetrics.pageMargin,
            height: WindowMetrics.deskPadding + WindowMetrics.pageMargin)
        if textContainerInset != inset { textContainerInset = inset }
    }
```

With `widthTracksTextView`, the text container is the view's width minus twice the inset,
which is always 612 − 2 × 72 = 468 pt: the 6.5 in column. `lineFragmentPadding = 0` stops
TextKit adding its default 5 pt on each side. The view is vertically resizable with a minimum
height of one page plus the desk's padding, so the sheet is never shorter than a page and
grows as the scene does.

One view means one coordinate space for clicks, selection, scrolling and (later) zoom, which is
PLAN's `NSScrollView` magnification. And because the text view's enclosing scroll view is the
desk, `usesFindBar = true` puts the standard find bar above the desk with no further code;
Cmd+F reaches it through `TextEditingCommands()`, the standard Find menu, added in
`SceneItApp`.

## 4. The text storage is a mirror; the model is the truth

`OpenBook` holds the book, and every edit goes through it so autosave hears in the same
main-actor turn (chapters 03a and 04). The text storage is therefore a *mirror*: built from the
model when a scene opens, and every change to it pushed back to the model at once.

**Loading** is the codec's `attributedString(forBody:)`, with the storage's delegate told to
ignore the edit it causes:

```swift
        isLoading = true
        storage.setAttributedString(RunCodec.attributedString(forBody: body))
        isLoading = false
```

**Syncing** happens in the text storage's delegate. Every change to an `NSTextStorage` (a
keystroke, a paste, an undo, a spelling correction) is bracketed by `beginEditing()` /
`endEditing()`, explicitly or implicitly, and ends in `processEditing()`, which reports the
edited range and how much the length changed to the delegate. That's the one place no edit can
get past, so it's where the page tells the model:

```swift
extension PageEditor: @MainActor NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isLoading else { return }
        sync(edited: editedRange, in: textStorage)
    }
}
```

`@MainActor NSTextStorageDelegate` is an *isolated conformance* (Swift 6.2): `NSTextStorage`
isn't tied to the main thread, so its delegate protocol isn't either, but this conformance
only holds on the main actor, which is where the page's storage lives. (TextKit 2's
`NSTextContentStorage` watches the storage through a separate observer property, so the
delegate is free for us.)

### Not converting the whole scene per keystroke

The obvious sync is `RunCodec.body(from: storage)` and `replaceBody`. Measured on a
10,000-word scene in a debug build, that conversion alone costs **about 20 ms**, every
keystroke. Instead, an edit becomes a `BodyChange`: *these lines of the old body are replaced
by these new paragraphs*. Only the lines the edit touches are converted again:

```swift
    public static func bodyChange(edited: NSRange, in text: NSAttributedString, linesBefore: Int)
        -> BodyChange?
    {
        let string = text.string as NSString
        guard edited.location >= 0, edited.upperBound <= string.length,
            let (region, before, linesAfter) = LineBreaks.scan(string, around: edited)
        else { return nil }
        let paragraphs = lines(from: text.attributedSubstring(from: NSRange(region)))
        let replaced = paragraphs.count - (linesAfter - linesBefore)
        guard replaced >= 0, before + replaced <= linesBefore else { return nil }
        return BodyChange(lines: before..<before + replaced, paragraphs: paragraphs)
    }
```

The arithmetic needs no record of what was deleted. Everything before the edited lines and
everything after them is unchanged, so if the text now has `linesAfter` lines and the edited
region holds `paragraphs.count` of them, the region replaced `paragraphs.count − (linesAfter −
linesBefore)` old ones. A property test applies thousands of random edits (every kind of line
break, `\r\n` split across the edit, emoji split mid-surrogate) and checks that the ranged
change always gives what converting the whole text gives.

Two performance lessons came out of this:

- **Swift loops are slow in debug builds.** A first version walked the UTF-16 units in Swift to
  count line breaks: 7 ms per keystroke at `-Onone`, about 140 ns per character. The test host
  and the app's Debug configuration both build `SceneItCore` unoptimized, so that's what the
  writer would feel while developing. Counting with `NSRegularExpression.numberOfMatches`, which
  runs in ICU's C++, costs well under a millisecond.
- **Foundation's `rangeOfCharacter(from:)` gives up at a lone surrogate.** Searching for
  `CharacterSet.newlines` in a string that holds an unpaired UTF-16 surrogate *before* the
  newline returns "not found". An `NSString` can hold lone surrogates (chapter 06 §6), so that
  version was wrong, not just slow. The property test caught it, and the `guard` above turned
  the miscount into a safe `nil` rather than a wrong edit.

The result: **about 1.2 ms per keystroke** end to end on a 10,000-word scene (the edit, the
ranged conversion and `OpenBook.apply`, in a debug build), measured by
`aKeystrokeInATenThousandWordSceneIsCheap`.

`OpenBook.apply(_:to:adding:)` applies the change, adjusts the cached word count by the
replaced and new paragraphs' counts (exact, since a paragraph break always ends a word), and
sends `.edited`. It also enforces the model rule the codec can't (book format §7.5): a comment
id the scene has no comment for is stripped before the store accepts the paragraphs, so a
stray id can never make a save fail verification.

**When the model changes from elsewhere** (an Errors-tab repair, say), `updateNSView` finds the
model's body isn't the one the storage mirrors and rebuilds the storage. `OpenBook` clears that
scene's page undo history at the same moment, because the old undo steps describe text that is
gone.

Between the two there's a gap: SwiftUI calls `updateNSView` on its next update, not at once.
SwiftUI's update ordering should keep a keystroke out of it, since every event gets its own
run-loop pass, but a test (or future code) can change the model and then edit the page in the
same turn. That's a backstop with one rule: the model, the source of truth, wins. The edit is
dropped, the page reloads from the model next turn, its undo history is cleared (its steps
describe text that's gone, and replaying them would delete the wrong characters), and the event
is logged, so it never happens silently. An earlier version tried to merge the two changes; it
was effectively unreachable, and its undo steps had stale offsets.

**Leaving a scene mid-edit.** Every keystroke reaches the model in its own turn, so when the
writer opens another scene there's nothing pending on the page to lose: the page only breaks its
undo coalescing, so the next scene's first keystroke starts a fresh undo step. (Before ADR 0028
there was: an input method's half-composed word lived only on the page, and a scene switch
could carry it into the next scene. Removing input methods removed that whole class of bug; see
section 5.) The title field is different, because its field editor keeps the text until the
editing ends, so a scene switch ends the title's editing first, in the scene it was typed in.

**Paragraph breaks have no format.** A break typed after bold text would carry bold attributes
in the storage, which the model can't hold. The storage delegate's
`textStorage(_:willProcessEditing:…)` (the one point where a delegate may still change the
edited text) resets every break in the edited range to the body role's attributes, so the page
stays an exact mirror.

## 5. Delegate veto points

`NSTextView` asks its delegate before every change to the text:
`textView(_:shouldChangeTextInRanges:replacementStrings:)`. Returning `false` cancels the
change. It's called for typing, autocorrection, text replacement, Find and Replace, dictation:
everything that changes characters through the view. The page uses it to apply ADR 0028's
character policy, so the page never holds a character the model can't:

```swift
        guard let strings = replacementStrings, let view = textView as? ManuscriptTextView else { return true }
        guard let admitted = KeyboardTextView.corrected(strings, by: CharacterPolicy.admittedInput) else {
            return true
        }
        view.replace(affectedRanges.map(\.rangeValue), with: admitted)
        return false
```

When the policy changes the text (a pasted `—` becomes `--`, `é` becomes `e`), the change is
refused and the admitted text is put in its place (compared as UTF-16 code units, since Swift's
`String ==` is canonical equivalence and what arrives here hasn't been admitted yet: it can hold
anything, down to a lone surrogate), in the format of the text it replaces (so Find and Replace
of an italic, commented `hi` with `“hi”` keeps both), or in the typing attributes when it's
inserted at the caret. `replace` goes through the same front door:
`shouldChangeText(inRanges:replacementStrings:)` (which calls this delegate again, now with
nothing to change, and registers the undo), the storage edit, then `didChangeText()`. The
selection is then carried through the edit: a caret where the writer typed goes after the
admitted text, which can be longer or shorter than what was typed, and a caret elsewhere (a
spelling correction replaces a word behind it) stays with the text around it
(`KeyboardTextView.selection(_:after:)`).

Should anything ever change the storage without asking (no known path does), the page's
storage delegate notices a character the policy doesn't admit in the edited range: the model
has already taken the admitted reading, and the page reloads from it once the edit is over. That
backstop is a scan of the edited range only, so it costs nothing per keystroke. Writing Tools is
off on every `KeyboardTextView` for the same reason: it rewrites text in ways the veto can't be
shown to see.

Two subtleties:

- **No input methods (ADR 0028).** An input method (Japanese or Chinese, but also the Option
  dead keys and press-and-hold accents) builds up *marked text*: uncommitted, underlined, and
  replaced as the writer goes on typing. Marked text is text on the page the model hasn't
  agreed to, and it caused a real data-loss bug (#72: a scene switch mid-composition deleted
  text). Since the book can only hold ASCII anyway, every editor of manuscript text is a
  `KeyboardTextView`, whose `inputContext` is `nil`:

  ```swift
  class KeyboardTextView: NSTextView {
      override var inputContext: NSTextInputContext? {
          nil
      }

      override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
          let plain = (string as? NSAttributedString)?.string ?? string
          insertText(plain, replacementRange: replacementRange)
      }
  }
  ```

  With no input context, `interpretKeyEvents` hands keys straight to the key bindings, which
  type them with `insertText`, so there's never any marked text, and the `setMarkedText`
  override makes sure of it should anything call that directly. The page, the title field's
  own field editor and (when it lands) the notes editor all inherit it. What the writer loses:
  **accents can't be typed at all.** Option-E then E, press-and-hold on `e`, and every IME are
  gone on the page and in the title. Accented text pasted in arrives as its plain letters
  (`Renée` becomes `Renee`, with no warning), and Greek or Japanese becomes `[?]`.
- **Smart quotes are off.** `isAutomaticQuoteSubstitutionEnabled = false` and the dash
  equivalent: the policy would spell them in ASCII straight back. Print and Word export
  smarten quotes on the way out (ADR 0022).

## 6. `typingAttributes`

`typingAttributes` is what the next typed character gets. `NSTextView` sets it from the
character before the caret whenever the selection changes, which is how typing after a bold
word continues bold. It would also continue a *comment*, and PLAN §8.1 says typing at the edge
of a commented span must never extend it. So on every selection change, the page passes the
attributes through the codec's format:

```swift
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = textView else { return }
        view.typingAttributes = ParagraphRole.body.typingAttributes(continuing: view.typingAttributes)
    }
```

`typingAttributes(continuing:)` reads the styles, color and highlight with the same `RunFormat`
the codec saves with, drops the comments, and renders the result in the body role. So typing
always gets exactly the attributes the codec would give that run on load: the body's font,
spacing and indent, never a foreign one.

## 7. The pasteboard

Copy and paste in an `NSTextView` go through four overridable members:

| Member | Used by |
| --- | --- |
| `writablePasteboardTypes` | copy, cut, drag: which types to offer |
| `writeSelection(to:type:)` | writing one of those types |
| `readablePasteboardTypes` | paste, drop: which types to accept, in order of preference |
| `readSelection(from:type:)` | reading the chosen type into the text |

The page offers its own type first, then whatever `NSTextView` already writes (RTF and plain
text, for other apps). It reads its own type, then RTF, RTFD and HTML (so bold and italic from
Pages, Word or a browser survive), then plain text. **Every** read goes through one function:
the pasted text is converted to paragraphs with the codec, which keeps only what a `Run` can
hold (chapter 06 §6: foreign fonts, colors without palette names, underlines and attachments
are dropped; line breaks become paragraph breaks), and the paragraphs are rendered back with
the codec and inserted. The page and the model see the same thing.

**The app's own type** (decision 0017) carries what RTF can't: palette colors, highlights and
comments. `PageClip` holds the copied lines, the comments they mention and the scene they came
from, and travels as a one-scene `book.md`:

```swift
    public var data: Data? {
        let holder = BookScene(
            id: scene, modified: BookFormat.rereadTime, title: "", body: lines, comments: comments)
        return try? BookFormat.verifiedSerialization(of: Book(title: "", scenes: [holder]))
    }
```

That reuses the format's exact encoding and its save verification, and the reading side is
the parser that never fails. On paste, `OpenBook.resolve(_:into:)` decides the ids: pasting
into the same scene while the comment still exists keeps the id, so cut and paste is lossless;
anything else gets a copy of the comment with a fresh id.

## 8. Undo managers

An `NSTextView` registers undo actions on whatever `undoManager` returns, and asks its delegate
first. PLAN §8.6 wants one history per scene, kept for the session, so the delegate hands out
the scene's own manager, which `OpenBook` keeps:

```swift
    func undoManager(for view: NSTextView) -> UndoManager? {
        scene.map(book.pageUndo(for:))
    }
```

Switching scenes swaps the text in the same view, so the next keystroke registers on the new
scene's manager, and coming back to a scene finds its history where it was left. An undo is
an ordinary edit as far as the storage is concerned, so it reaches the model through the same
`didProcessEditing` sync, and autosave hears of it in the same turn.

**Grouping.** `UndoManager.groupsByEvent` (on by default) opens a group at the first
registration in an event and closes it when the run loop finishes the event. A test has no
events, so after typing the group is still open (the page tests saw `groupingLevel == 1` half a
second later). `undo()` copes: it closes an open top-level group before undoing, so the tests
call it directly. (`undoNestedGroup()` is documented to raise an Objective-C exception
instead.)

**Order inside a group matters.** A paste that brings comments in is one group with two
actions: remove the new comments, and the text change. Undo runs a group's actions in reverse
order of registration, so the comment removal is registered *first*, to run *last*:

```swift
        if !comments.isEmpty {
            // Registered before the text, so undoing the paste takes the text away first and no
            // run is ever left naming a comment the scene doesn't have.
            let ids = Set(comments.map(\.id))
            undo.registerUndo(withTarget: book) { $0.removeComments(ids, from: scene) }
        }
```

`removeComments` registers putting them back, so redo works the same way in reverse.

**Routing.** Cmd+Z sends the `undo:` action down the responder chain, and the window asks the
first responder for its undo manager, so the focused text view's own manager answers. The
toolbar's Undo and Redo, and the rule that sends them to `OpenBook.structureUndo` while the
Scenes sheet is open, are [chapter 07](07-undo.md)'s subject.

## 9. The title field and its own field editor

The title (decision 0015) is an `NSTextField`. Text fields don't edit their own text: the
window lends the focused field a shared `NSTextView`, the **field editor**, while it has the
focus. That's why a title test finds an `NSTextView` behind the field, and why settings on the
field editor would leak to every other field in the window. The title needs continuous
spellchecking that other fields shouldn't get, and no input method (section 5), so its cell
supplies a field editor of its own, a `KeyboardTextView`:

```swift
        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            editor
        }
```

The title has the same veto, in its field editor's `shouldChangeText(inRanges:replacementStrings:)`
override (the field's delegate isn't asked about changes): a change the title can't hold is
refused and its admitted reading made instead. An earlier version let the change happen and then
assigned the admitted text to `editor.string` from the field's delegate. That isn't an undoable
change, so the typing's undo step, recorded against the old text, was replayed over the corrected
one: type `©` after `One`, get `One(c)`, press Cmd+Z, get `Onec)`. Every correction has to be an
edit the undo manager has seen.

Return and Tab arrive at the field's delegate as *commands*
(`control(_:textView:doCommandBy:)`), not as characters; the title turns both into "move to the
start of the body" through `PageFocus`. Shift-Tab at the very start of the body comes back
(`insertBacktab` in `ManuscriptTextView`).

## 10. Testing a text view without touching the screen

Agents working on Scene It never synthesize keystrokes or clicks: those could reach whatever
app is frontmost (WORKFLOW.md). The page tests host the real `BookWindow` in an offscreen window
of our own and call the same methods the system would:

| The writer… | The test calls |
| --- | --- |
| types | `insertText(_:replacementRange:)`, `insertParagraphSeparator(_:)` |
| copies or cuts | `writeSelection(to:types:)` on a private `NSPasteboard`, then `delete(_:)` |
| pastes | `readSelection(from:)` on that pasteboard |
| presses Cmd+Z | `tryToPerform(_:with:)` with the `undo:` action, as the menu does |
| presses Return in the title | the field editor's `doCommand(by:)` |

A private pasteboard (`NSPasteboard(name:)` with a unique name, released afterwards) keeps the
writer's clipboard untouched. Each test then checks the model, the page (`pageMirrorsModel`:
the storage equals the codec's rendering of the model) and, where it matters, the `book.md`
autosave wrote.

The page fuzz (`PageFuzzTests`) makes random edits through every one of those paths and checks
the model after each edit and the page once the turn is over. The commit gate runs a small
amount of it (2 seeds × 200 steps) so the gate stays fast; set `TEST_RUNNER_PAGE_FUZZ_SEEDS` and
`TEST_RUNNER_PAGE_FUZZ_STEPS` for a longer run (the README's Scripts section has the command).

**Drive AppKit from the run loop, not from inside a task.** The review's fuzz test first ran
its 1,500 edits per seed as a loop inside the (main-actor) test task, and the app crashed later
in a SwiftUI render, inside `swift_task_isCurrentExecutor`, reading a pointer that was 0x1 or
ASCII text. The cause was in the harness: a helper compared strings with Swift's `==`, which
compares *canonical equivalence* (`é` equals `e` + U+0301 at a different length), then indexed
the shorter `NSAttributedString` past its end. That raised an Objective-C `NSRangeException`.
An Objective-C exception unwinds through Swift frames without running any Swift cleanup, and
here it unwound through the concurrency runtime's job runner up to `NSApplication`'s handler,
which caught it and carried on. The runner never restored the thread's record of the current
executor, which was left pointing into a dead stack frame; the next isolation check read
whatever had since been written there. The test now compares code units, and runs each step
from `RunLoop.main.perform`, as an event's handling runs, so an exception there behaves as it
would in the app. Since [ADR 0026](../decisions/0026-crash-on-exceptions.md) the app
itself stops at once on such an exception instead of carrying on.
