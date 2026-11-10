# 0049 — Scene It's text never goes to an AI or language model

**Status:** Accepted (2026-11-09, the owner's request). **Amends [0028](0028-strict-ascii-no-input-methods.md)**:
word predictions are no longer the writer's to turn on. The public wording below is a proposal; the
owner chooses the words on the site.

## Context
The owner wants the website to say plainly that what a writer types in Scene It never goes through or
into an AI or language model, and wants that sentence to be exactly true. Scene It was written with the
help of AI coding tools (Claude, from Anthropic). The question here is what the shipped app does with
the writer's text.

An audit (2026-11-09, macOS 27.0.1, Xcode 27.2) found that the app itself contains no AI, but that
macOS offered two language-model features inside it:
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
1. **No AI in the app.** No machine-learning, language or AI framework is linked or imported: no
   CoreML, CreateML, NaturalLanguage, FoundationModels, Speech, Translation, Vision, VisionKit,
   ImagePlayground or SoundAnalysis. Search is Scene It's own keyword index (`KeywordSearch`); sentence
   and word boundaries come from Foundation's `enumerateSubstrings` (rule-based text segmentation), not
   a model. The app has no App Intents and offers its content to no Siri or Apple Intelligence feature.
2. **Nothing is sent anywhere.** The app has no networking code: no `URLSession`, `URLRequest`, Network
   framework, CloudKit or web view (WebKit appears only in tests, to render previews). Books
   are files on the Mac. The one thing that can leave the Mac is Help › Report a Problem's zip, which
   the writer emails themselves through Mail; it holds logs, crash reports and settings, and no text
   from any book (ADR 0006). Scene It never needs an internet connection.
3. **Writing Tools and word predictions are off in every text view.** Scene It's editors (the page,
   the notes, titles, comment cards, the + tag fields, File a Copy's tags and note, the Errors tab's fix)
   are `KeyboardTextView`s, whose `writingToolsBehavior` is always `.none`, `inlinePredictionType`
   always `.no` and `isAutomaticTextCompletionEnabled` always `false`: setting them does nothing. Every
   other text view the focus reaches (SwiftUI's fields, the find bar's field) gets the same three
   settings as it takes the focus, before a key reaches it (`LanguageModelsOff`, applied once at the
   root of the book window and of the dialog frame), and SwiftUI's fields are told
   `.writingToolsBehavior(.disabled)`.
4. **The menus offer no Writing Tools.** Scene It takes AppKit's Writing Tools submenu, and the
   separator before it, out of the main menu at launch, and again whenever AppKit adds it back.
5. **Spell checking and reading aloud are macOS's, on the Mac.** Spelling and grammar underlines,
   corrections and substitutions come from `NSSpellChecker`, the system's spelling service on the Mac.
   Read aloud uses `AVSpeechSynthesizer`, and the Edit menu's Speech › Start Speaking uses AppKit's own
   speech; both speak with the system voices, on the Mac (ADR 0044).

**Enforced by:**
- `LanguageModelsOffTests`: walks the book window's view tree with each right-panel tab, the find bar,
  each sheet (Scenes, Search, File Cabinet) and File a Copy's dialog open, gives every field the focus,
  and checks that every text view and field editor has all three off; checks that the main menu holds
  no Writing Tools item, and that one added back is taken out again.
- `AdversarialPageTests`: the page and the title can't have them turned back on.
- `no-ai-guard` in `scripts/guards.sh` (run by `check.sh`, tested by `test-guards.sh`): fails on an
  import of any framework above, of Network or CloudKit, and on `URLSession`, `URLRequest`,
  `NWConnection`, `NWListener`, `NWBrowser`, `NSURLConnection` or `CKContainer`.

**Outside Scene It's control:**
- **Dictation.** The writer enables it for the whole Mac (System Settings › Keyboard); Apple's speech
  recognition, a model, turns speech into text before Scene It sees it. Scene It's editors have no
  input context (ADR 0028), so dictation may not reach them at all; what it does deliver is typed text.
- **Voices.** Downloading a better voice is done in System Settings, from Apple; it sends no text.
  Downloaded Siri and premium voices are neural voices that run on the Mac.
- **Text the writer hands to another app or service**: copying or sharing it, the Services menu, and
  the items macOS adds to a search field's context menu when text is selected (Look Up, Translate,
  Search With…, Share). Translate is Apple's translation, which may run on Apple's servers. The page's
  context menu offers Search With… (it hands the selection to the browser) but not Look Up, Translate
  or Share.
- **System features at the Mac level**: Apple Intelligence or Siri reading the screen, screen sharing,
  screenshots, accessibility tools. Writing Tools' system-wide entry points act through the focused
  text view, which declines (`writingToolsBehavior` is `.none`); that is AppKit's contract and wasn't
  tried by hand, since agents never synthesize input.
- **macOS's own autocorrection**, if the writer turns on Correct Spelling Automatically (it starts
  off, ADR 0028). Apple doesn't document what drives it on recent macOS; if it uses a language model,
  that model runs on the Mac, and what it types goes through the character policy like any typing.

## The public wording it supports
Exactly true, from the above (the owner's call on the final words):

> Scene It was written with the help of AI coding tools (Claude, from Anthropic). The app itself
> contains no AI and uses no AI features: Scene It never sends what you write anywhere, and never
> gives it to an AI or language model to read, rewrite or learn from. Apple's Writing Tools and text
> predictions are switched off inside it. Everyday features such as spell checking and reading aloud
> are provided by macOS itself, on your Mac. Scene It never needs an internet connection.

It speaks for the app (what Scene It does), not for what the writer does with macOS outside it, which
the list above covers.

## Alternatives
- **Leave Writing Tools in the menu, disabled.** The views already refuse it, so its items would be
  greyed out. Rejected: a greyed-out "Rewrite" still suggests the app has it.
- **Keep predictions the writer's choice** (ADR 0028 as it was). Rejected: the claim would then depend
  on a setting.
- **Take Look Up, Translate and Share out of the search fields' context menus.** SwiftUI owns those
  fields and their menus, so it would mean reaching into its views; they are hand-offs the writer
  chooses, like copying.

## Learning notes
`writingToolsBehavior` and `inlinePredictionType` belong to every `NSTextView` (they come from
`NSTextInputTraits`), and a text field types with its *field editor*, a text view that the window or
the field supplies while it's being edited. SwiftUI gives each of its fields a field editor of its own
(not the window's), with Writing Tools `.limited` unless `.writingToolsBehavior(.disabled)` is in the
environment. Watching the window's `firstResponder` (key-value observable) catches whichever field
editor takes the focus, whoever made it.
