# 07h — Read aloud: a system synthesizer behind a seam

Issue #39 (PLAN §10.3, ADR 0044). Select text on the page and press ▶ (Cmd+Shift+R): the Mac
reads the selection aloud, the sentence being read is highlighted, and ▶ becomes ■ until the
reading ends. The Swift and macOS lessons: `AVSpeechSynthesizer` and the delegate pattern; a
small protocol in front of a system service, so tests never make a sound; delegate callbacks that
arrive off the main actor; a generation counter against late events; UTF-16 offsets; and drawing
that is display-only, never written to the document.

Files: [`SceneIt/Editor/Speech.swift`](../../SceneIt/Editor/Speech.swift),
[`SceneIt/Editor/ReadAloud.swift`](../../SceneIt/Editor/ReadAloud.swift),
[`Sources/SceneItCore/Text/SpokenText.swift`](../../Sources/SceneItCore/Text/SpokenText.swift),
[`SceneIt/Editor/ManuscriptTextView.swift`](../../SceneIt/Editor/ManuscriptTextView.swift),
[`SceneIt/Window/FormattingBar.swift`](../../SceneIt/Window/FormattingBar.swift),
[`SceneItTests/ReadAloudTests.swift`](../../SceneItTests/ReadAloudTests.swift).

## 1. `AVSpeechSynthesizer` and its delegate

`AVSpeechSynthesizer` takes an `AVSpeechUtterance` (a string, a voice and a rate) and speaks it on
the Mac itself; nothing leaves the machine (ADR 0044). It reports progress through a **delegate**:
an object you hand it, conforming to `AVSpeechSynthesizerDelegate`, whose methods it calls as
things happen. The Rust analog is a `Box<dyn Listener>` the library holds and calls back, except
that the synthesizer holds its delegate *weakly*: the delegate must be kept alive by someone else.
Three of its methods matter here:

```swift
extension SystemSpeech: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        deliver(.willSpeak(characterRange), about: utterance)
    }
```

`willSpeakRangeOfSpeechString` arrives before each word with that word's range in the utterance's
string; `didFinish` and `didCancel` arrive when it ends either way. Every delegate method names the
utterance it's about, which matters once one reading can be stopped and another started.

## 2. A protocol in front of the system service

The app never talks to `AVSpeechSynthesizer` directly. It talks to a two-method protocol, and
reports come back as an enum:

```swift
protocol SpeechSynthesizing: AnyObject {
    /// Speaks `request`, reporting each event to `events` on the main actor. Speaking stops
    /// whatever was being spoken.
    func speak(_ request: SpeechRequest, events: @escaping (SpeechEvent) -> Void)
    func stop()
}
```

`SystemSpeech` adapts the real synthesizer to it; `RecordedSpeech`, which the test host and
previews get from `BookController`, records requests and reports only what a test plays through
`report(_:)`. This is a trait with two impls, chosen once at construction by process role, the
same way the app picks its preference storage and its alerts. Tests can then drive the delegate's
sequence (a word, another word, the end) deterministically and without audio, and the adapter is
small enough to read in one sitting.

## 3. Callbacks off the main actor

The app target defaults to `@MainActor` (ADR 0011), but the synthesizer may call its delegate on a
queue of its own. So the delegate methods are `nonisolated`, take out only what's `Sendable` (an
`NSRange`, an `ObjectIdentifier`), and hop to the main queue:

```swift
    private nonisolated func deliver(_ event: SpeechEvent, about utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.report(event, about: id) }
        }
    }
```

`MainActor.assumeIsolated` is a checked assertion, like Rust's `debug_assert!` that you're on a
thread, that lets the compiler treat the block as main-actor code. A `Task { @MainActor in … }`
would also compile, but tasks aren't guaranteed to run in the order they were made, and a word's
event must never overtake the end's.

`ObjectIdentifier` is the object's address. An address is reused once the object is freed, so the
adapter keeps each utterance alive in its table until its last event has arrived: otherwise a
stopped utterance's late `didCancel` could be taken for a new utterance allocated at the same
address.

## 4. One state enum, and a generation counter

`ReadAloud` holds the reading as one enum, so "reading with no text" or "idle with a highlight"
can't be represented:

```swift
    enum State: Equatable {
        case idle
        case reading(Reading)
    }
```

The button's look follows from it and the page's selection (`Control`: `.unavailable`, `.read`,
`.stop`). Stopping and starting again quickly is the classic race: the first reading's `didCancel`
can arrive after the second has started. Each `speak` gets a number, the closure captures it, and an
event whose number isn't the current reading's is dropped, which is the same trick as a generation
counter guarding a stale future in async Rust.

Reading stops when the page's text changes (it observes the text storage's
`didProcessEditingNotification` and checks `editedMask.contains(.editedCharacters)`), when another
scene opens, when a sheet opens and when the window goes. Stopping on any character change, rather
than only on edits inside the selection, keeps the rule simple and the stored ranges always valid.

## 5. UTF-16 offsets, not characters

`NSString`, `NSTextStorage` and the synthesizer all count UTF-16 code units, not `Character`s
(Swift's grapheme clusters) or bytes (Rust's `str` indices). An emoji is two units; with a skin tone,
four; a decomposed `é` is two scalars. Because the utterance is the selection's own `NSString`
substrings, a range of the utterance maps back to the page by adding where its piece starts, with
no counting of characters at all. `SpokenText` does that, finds the sentence around the spoken word
with `enumerateSubstrings(options: .bySentences)`, and is a pure core type, so its tests run in
`swift test` without a window.

## 6. Display-only drawing

The highlight must never reach the document: the text storage mirrors the model, and anything put
in it would be saved. TextKit 2 has a display-only layer for exactly this, *rendering attributes*:
`NSTextLayoutManager.addRenderingAttribute(_:value:for:)` colors a range as it's drawn without
touching the storage. The page already uses one, `.backgroundColor`, to paint the selection's color
over highlighted words the selection covers (ADR 0034). Two owners of one attribute would erase each
other's ranges, so the spoken sentence joins that same code, set last so it wins:

```swift
        for range in highlighted.compactMap(textRange(of:)) {
            layout.addRenderingAttribute(.backgroundColor, value: backgrounds.color, for: range)
        }
        for range in spoken.compactMap(textRange(of:)) {
            layout.addRenderingAttribute(.backgroundColor, value: Self.spokenSentenceColor, for: range)
        }
```

A first version drew the sentence as a band in `drawBackground`, under the text like the selection.
It broke up wherever the sentence held a highlighted word: TextKit draws rendering attributes with
the text, above anything the view's background draws. Tests check that the storage is the same after
a sentence is highlighted, and that the sentence is one color across a highlighted word.

## 7. A shortcut on a button

Every other shortcut in Scene It is a menu item's. ▶'s is the button's own
(`.keyboardShortcut(.readAloud)`): PLAN §6.2 gives the shortcut to the bar's button, which stays in
focus mode, and SwiftUI disables it with the button, so under a sheet Cmd+Shift+R does nothing.

The key is written `"R"` with Shift. `charactersIgnoringModifiers` is documented to ignore every
modifier except Shift, so a real Cmd+Shift+R can arrive spelled `"R"`. Tried in
the hosted test, a shortcut written `"r"` matched only an event spelled `"r"`; written `"R"`, it
matched both spellings. The test presses the key as `NSApplication.sendEvent` hands it on, offering
it to the window's `performKeyEquivalent` first; calling `NSApp.sendEvent` itself reaches nothing
in the test host, whose windows are never really key.
