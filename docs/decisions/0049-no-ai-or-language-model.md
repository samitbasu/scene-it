# 0049 — Scene It's text never goes to an AI or language model

**Status:** Accepted (2026-11-09, the owner's request; the public wording is the owner's, approved
2026-11-09). **Amends [0028](0028-strict-ascii-no-input-methods.md)**: word predictions are no
longer the writer's to turn on.

## Context
The owner wants the website to say plainly that what a writer types in Scene It never goes through or
into an AI or language model, and wants that sentence to be exactly true. Scene It was written with the
help of AI coding tools (Claude, from Anthropic). The question here is what the shipped app does with
the writer's text.

An audit (2026-11-09, macOS 27.0.1, Xcode 27.2) found that the app itself has no AI, but that macOS
offered two language-model features inside it:
- **Apple Intelligence's Writing Tools.** AppKit adds a Writing Tools submenu (Proofread, Rewrite,
  Summarize, Compose…) to the Edit menu of every app. Scene It's own editors already refused it
  (`KeyboardTextView`, ADR 0028), but SwiftUI's text fields (the Search, Scenes and File Cabinet
  filters, the Comments search) offered it in their context menus (`writingToolsBehavior` was
  `.limited`).
- **Word predictions.** Every text view, including Scene It's editors, followed the system's inline
  predictions (the grey suggestion ahead of the caret) and the Touch Bar's word candidates. ADR 0028 only
  set where they started (off), and System Settings could turn them on.

## Decision
**What Scene It guarantees:**
1. **No AI of its own.** The app's code imports no machine-learning, language or AI framework (CoreML,
   CreateML, NaturalLanguage, FoundationModels, Speech, Translation, Vision, VisionKit, ImagePlayground,
   SoundAnalysis), no Siri or Shortcuts framework (AppIntents, Intents), and calls no
   `NSLinguisticTagger`. Search is Scene It's own keyword index (`KeywordSearch`); sentence boundaries
   for read aloud come from Foundation's `enumerateSubstrings`, which is rule-based segmentation.
2. **Nothing is sent anywhere.** The app's code calls no networking API: no `URLSession`,
   `URLRequest`, `NSURLConnection`, Network framework, CFNetwork streams or sockets, CloudKit, or a
   `Data`/`String` read from a web address, and the app (unlike its tests) doesn't import WebKit.
   - **Pasted HTML fetches nothing.** Paste reads HTML through `NSAttributedString(html:)`, which is
     WebKit's importer, and pasted HTML can name images, style sheets, scripts and frames on a server.
     On macOS 27 the importer fetches none of them: `HTMLPasteTests` pastes HTML naming each kind at a
     server on the Mac's loopback address (by `127.0.0.1` and by `localhost`, over HTTP and HTTPS) and
     checks that no connection reached it. The server counts connections from any process, so this
     covers WebKit's own networking process too. The test also records every request the URL loading
     system is asked for, but that sees only requests made inside Scene It's process, so it adds
     nothing about WebKit's. What's proven is that these references, at this server, aren't fetched;
     that the importer would treat a reference to another host the same way is an inference, not a
     test. The test runs in the gate, so a macOS that starts fetching fails it.
   - Books are files on the Mac. The one thing that can leave the Mac is Help › Report a Problem's
     zip, which the writer emails themselves through Mail; it holds logs, crash reports and settings,
     and no text from any book (ADR 0006).
   - Scene It never needs an internet connection.
3. **Writing Tools and word predictions are off in every text view in Scene It's windows.** Scene It's
   editors (the page, the notes, titles, comment cards, the + tag fields, File a Copy's tags and note,
   the Errors tab's fix) are `KeyboardTextView`s, whose `writingToolsBehavior` is always `.none`,
   `inlinePredictionType` always `.no` and `isAutomaticTextCompletionEnabled` always `false`: setting
   them does nothing. Every other text view that takes the focus in any of the app's windows (SwiftUI's
   fields, the find bar's, an alert's) gets the same three settings as it takes the focus, before a key
   reaches it (`FocusedTextWatch`, which the app delegate starts at launch and which watches each window
   from its first update; the window holds its watch, so it goes with the window however the window
   goes away), and SwiftUI's fields are told `.writingToolsBehavior(.disabled)`
   (`languageModelsOff()`, at the root of the book window and of the dialog frame).
4. **The menus offer no Writing Tools.** Scene It takes AppKit's Writing Tools submenu, and the
   separator before it, out of the main menu at launch, and again on the next turn of the run loop
   whenever an item is added to any menu. Only an item whose action is `showWritingTools:`, or a submenu
   holding nothing but such items, is taken out, so no other menu can be. Because the removal waits for
   the next turn, a Writing Tools item that AppKit inserted only as a menu opened (it inserts it at
   launch on macOS 27, so this wasn't seen) would show for that one opening. Every text view would
   still decline it.
5. **Spell checking and reading aloud come from macOS and run on the Mac.** Spelling and grammar
   underlines, corrections, completions and substitutions come from `NSSpellChecker`, the system's
   spelling service. Read aloud uses `AVSpeechSynthesizer`, and the Edit menu's Speech › Start Speaking
   uses AppKit's own speech; both speak with the system voices (ADR 0044). Since macOS Sonoma, Apple's
   spelling, grammar and autocorrection may use language models that run on the Mac, and downloaded
   Siri and premium voices are neural voices that run on the Mac. Scene It keeps spell checking (the
   owner's call): these are macOS's own services, they run on the Mac, and nothing they do leaves it.
   Correct Spelling Automatically, the one of them that changes words, starts off (ADR 0028), and what
   it types goes through the character policy like any typing.
   - **Completion** (`complete:`, Option-Esc, or Esc in a text view that doesn't take Esc itself) shows
     `NSSpellChecker`'s list of words that begin with what's typed. Apple documents it as the spelling
     dictionary's completions of a partial word, not a prediction of the next one; it changes nothing
     unless the writer picks a word.

**Enforced by:**
- `LanguageModelsOffTests`:
  - walks the book window's view tree with the Notes, Comments and Tags tabs (the + tag field), the
    find bar, each sheet (Scenes, Search, File Cabinet), File a Copy's dialog and Export as SceneIt's
    chooser open, gives every field the focus, and checks that every text view and field editor has all
    three off; in each sheet it then changes the field's text from the model, so SwiftUI updates the
    field while it's edited, and checks again;
  - checks a plain AppKit field in a window of its own, which only the app-wide watch covers, and
    that nothing of a window's watch outlives the window when it's freed without being closed (so
    nothing is kept by its address), and that a new window is watched from its first update;
  - checks that the main menu holds no Writing Tools item, that one added to the Edit menu is taken out
    again with its separator, and that every top-level menu and the Edit menu's other items are left;
    and that a menu holding a Writing Tools item among others is never taken for one.
- `AutomaticTextChangeTests`: the Errors tab's fix field (hosted on its own) has all three off.
- `AdversarialPageTests`: the page and the title can't have them turned back on.
- `HTMLPasteTests`: pasted HTML fetches nothing it names (point 2).
- `no-ai-guard` in `scripts/guards.sh` (run by `check.sh`, tested by `test-guards.sh`), over the source:
  - an `import` of any framework in points 1 and 2, or of Network, CFNetwork or CloudKit;
  - `URLSession`, `URLRequest`, `NWConnection`, `NWListener`, `NWBrowser`, `NSURLConnection`,
    `CKContainer`, `CFStream…`, `CFSocket…` or `NSLinguisticTagger`;
  - `Data(contentsOf:` or `String(contentsOf:` with a `URL(string: "<scheme>://`;
  - `import WebKit` under `SceneIt/` and `Sources/` (the tests render previews with it).

  It checks the source, not what's linked, and like every guard it skips whole-line comments only (a
  trailing comment naming one of these is a hit). `HTMLPasteTests.swift` may use `URLRequest` and
  `URLProtocol`, to record requests; nothing else is allowed there.

**Outside Scene It's control:**
- **Dictation.** The writer enables it for the whole Mac (System Settings › Keyboard); Apple's speech
  recognition, a model, turns speech into text before Scene It sees it. Scene It's editors have no
  input context (ADR 0028), so dictation may not reach them at all; what it does deliver is typed text.
- **Downloading a voice** is done in System Settings, from Apple; it sends no text.
- **The open and save panels.** macOS shows them from another process: in the audit, an `NSSavePanel`
  or `NSOpenPanel` made in the test host held only a remote view (`NSRemoteView`) and no text view of
  the app's. So their name and search fields are system UI that Scene It can't switch. This was
  observed, not gated: making a panel waits on that other process, which made a test of it hang when
  the Mac was busy. Should a panel ever come into the app's process, `FocusedTextWatch` would cover
  its fields, as it does any window's.
- **Text the writer hands to another app or service**: copying or sharing it, the Services menu, and
  the items macOS adds to a search field's context menu when text is selected (Look Up, Translate,
  Search With…, Share). Translate is Apple's translation, which may run on Apple's servers. The page's
  context menu offers Search With… (it hands the selection to the browser) but not Look Up, Translate
  or Share.
- **System features at the Mac level**: Apple Intelligence or Siri reading the screen, screen sharing,
  screenshots, accessibility tools. Writing Tools' system-wide entry points act through the focused
  text view, which declines (`writingToolsBehavior` is `.none`); that is AppKit's contract and wasn't
  tried by hand, since agents never synthesize input.

## The public wording
The owner's, approved 2026-11-09; the points above support each sentence:

> Scene It was written with the help of AI coding tools (Claude, from Anthropic). The app itself has no
> AI of its own and never gives what you write to an AI service: Scene It never sends your words
> anywhere. Apple's Writing Tools and text predictions are switched off inside it. Spell checking and
> reading aloud come from macOS and run on your Mac; Apple may use on-device models for them, and
> nothing leaves your Mac. Scene It never needs an internet connection.

It speaks for the app (what Scene It does), not for what the writer does with macOS outside it, which
the list above covers.

## Alternatives
- **Leave Writing Tools in the menu, disabled.** The views already refuse it, so its items would be
  greyed out. Rejected: a greyed-out "Rewrite" still suggests the app has it.
- **Keep predictions the writer's choice** (ADR 0028 as it was). Rejected: the claim would then depend
  on a setting.
- **Turn spell checking off**, since macOS may use on-device models for it. Rejected by the owner:
  it's a macOS service that stays on the Mac, and the wording says so.
- **Read pasted HTML as plain text, or strip its references first.** Not needed while the importer
  fetches nothing, which the gate checks; either would lose the bold and italic a browser's HTML
  carries (ADR 0017).
- **Take Look Up, Translate and Share out of the search fields' context menus.** SwiftUI owns those
  fields and their menus, so it would mean reaching into its views; they are hand-offs the writer
  chooses, like copying.

## Learning notes
`writingToolsBehavior` and `inlinePredictionType` belong to every `NSTextView` (they come from
`NSTextInputTraits`), and a text field types with its *field editor*, a text view that the window or
the field supplies while it's being edited. SwiftUI gives each of its fields a field editor of its own
(not the window's), with Writing Tools `.limited` unless `.writingToolsBehavior(.disabled)` is in the
environment. Watching each window's `firstResponder` (key-value observable) catches whichever field
editor takes the focus, whoever made it.
