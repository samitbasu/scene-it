# 0028 — Strict ASCII text; no input methods on the page

**Status:** Accepted (2026-11-03). **Supersedes the "Characters" section of [0022](0022-markdown-book-format.md)** (Latin-1).
**Amended by [0049](0049-no-ai-or-language-model.md)** (2026-11-09): word predictions are off for good.
Breaking change while undeployed; the file stays `format: 2`.

## Decision
- **Stored and editable text is printable ASCII** (0x20–0x7E) plus the paragraph structure. `book.md` is therefore pure ASCII, and
  one character = one byte = one UTF-16 unit everywhere.
- **Input methods are disabled on the page and in the notes and title fields** (no input context), so there is no marked text and no
  composition state. Dead keys, press-and-hold accents and IME input aren't available.
- **Anything non-ASCII that arrives** (paste, drop, dictation, autocorrect, text replacement, a hand-edited file) goes through one
  explicit, versioned **transliteration table**: Latin-1 and Windows-1252 letters to their plain forms (é→e, ñ→n, æ→ae, ß→ss,
  ø→o), typographic punctuation to ASCII (“ ”→", ‘ ’→', —→--, –→-, …→...), NBSP to a space. Everything else becomes `[?]`.
  The table is the only place these rules live, and it's not a system transform (which could change between macOS versions).
- **Reading a file:** UTF-8 is decoded and invalid bytes fall back to Windows-1252 as before; then the table applies, plus one
  notice per kind of change (transliterated or replaced); typographic punctuation and NBSP are straightened silently (see "Details settled").
- **Existing Latin-1 books** (development only) open as repaired, read-only, with the original kept (ADR 0024).

## Why
The owner's call after the #72 review: input-method composition caused a real blocker (text deleted on a scene switch) and
a family of edge cases. ASCII removes that class entirely, and makes every offset and comparison trivial inside the model.

## Cost (accepted)
Accented names can't be written: pasted accents are converted to plain letters (names are altered silently). Typing accents via
Option-key dead keys or press-and-hold doesn't work. Non-Latin text becomes `[?]`. Dictation and the emoji & symbols
palette work through the input system, so on the page and in the title they may be unavailable, and anything they do deliver
goes through the table (an emoji becomes `[?]`). What Option-E itself produces with no input context isn't documented: AppKit's
headers put dead-key state in the text input system (`NSEvent.characters(byApplyingModifiers:)`), and without an input context
`interpretKeyEvents` hands the key to the key bindings, which type the event's `characters` through `insertText` and so through
the policy (a spacing `´` would become `'`). Not observed by hand yet (#74).

## Details settled in the implementation (#74)
- **The table is version 1**, lives in book format §1.2 as the source of truth, and `Transliteration.table` must equal it
  (`TransliterationTableTests` reads the spec). Every Latin-1 and Windows-1252 character beyond ASCII is either in it or
  listed there as deliberately left out (currency signs, superscripts, fractions, °, §, ¶, †, ‰…), which become `[?]`.
- **Decomposed input needs no normalization:** the table removes the eight combining accents that Latin-1 and
  Windows-1252 letters decompose into, so `e` + U+0301 reads as `e`, exactly as `é` does.
- **Transliteration runs per token, after the structure is read** (book format §1.2 step 7): decoding, line endings and
  tabs are file-level, but a character the table changes is spelled in ASCII only inside the text a line yields, so what
  the table writes is always literal text (a bullet's `*` never italicizes, a no-break space is never trimmed and never
  makes a line blank).
- **Typographic punctuation and the no-break space are straightened silently** in a file (the table's `silent` column,
  owner's call on #86), so a book edited in TextEdit opens normally. Every other entry, and every `[?]`, gets a notice,
  and so the book opens read-only as repaired (ADR 0024). Tabs and line endings stay silent. Typing and pasting are never
  noticed.
- **Input methods:** every manuscript editor is a `KeyboardTextView` (`inputContext` is `nil`; `setMarkedText` types its
  plain text instead), so marked text can't arise. Writing Tools is off on them too (`writingToolsBehavior` is always
  `.none`): it rewrites text through paths the veto might not see. The page and the title both veto a change the policy
  would alter and make the admitted one instead, as one undoable change; the page also reloads from the model if any edit
  ever leaves a character the policy doesn't admit. The Errors tab's fix field was a SwiftUI `TextField` that kept its input
  method until #127, which made it an `AdmittingTextField`: its line goes into the manuscript, so it's typed as the
  manuscript is, with no input method and only the characters the policy admits.
- **Automatic text changes are the writer's to switch, and start off (#127).** The owner saw the page change a word
  being typed. The Edit menu's Spelling and Substitutions submenus and a text view's context menu are the standard
  ones, and the writer turns each automatic change on or off there; AppKit keeps that choice in the app's own defaults.
  Scene It only chooses where they start: at launch it registers them off in the user-defaults registration domain
  (`AutomaticTextChanges.startingValues`), which is never saved and which the writer's choice and System Settings
  (Keyboard > Text Input) both outrank. No editor sets them itself, so a choice survives editors being rebuilt.
  The keys, found in AppKit and checked in the test host:
  - `NSAutomaticSpellingCorrectionEnabled`, `NSAutomaticQuoteSubstitutionEnabled` and
    `NSAutomaticDashSubstitutionEnabled` set a new text view's switches (registered on or off, the view follows).
  - `NSAutomaticTextCompletionEnabled` and `NSAutomaticInlinePredictionEnabled` set the spelling checker's switches.
    Text completion is the Touch Bar's list of candidate words (NSTextView's own `isAutomaticTextCompletionEnabled`,
    which stays on, only allows that list); it never changes the text unless the writer picks a word. Inline
    prediction is the grey suggestion ahead of the caret. *Both are now off for good (ADR 0049; see
    the amendment below).*
  - `NSAutomaticCapitalizationEnabled` and `NSAutomaticPeriodSubstitutionEnabled` are registered off, but they come
    from System Settings when it sets them, as it does on the owner's Mac; there they're on until the writer turns
    them off in System Settings.
  - Text replacement is left to macOS (the owner's call): no key the app registers reaches it, so it starts on, and
    the writer turns it off in the menu. Whether AppKit remembers that toggle across launches couldn't be checked
    without writing the app's real defaults; AppKit has no `NSAutomaticTextReplacementEnabled`-style key in its
    strings, unlike the others. To be checked by hand in a trial build.
  - Smart copy/paste has no key and starts on, as before.
  - Check Spelling While Typing (the underlines) stays on in every editor, set as each is made, as before: the
    owner's call. No AppKit key sets its starting value (`NSContinuousSpellCheckingEnabled`,
    `NSAllowContinuousSpellChecking` and `WebContinuousSpellCheckingEnabled` were registered, at launch and later, and
    a new text view still started without it). Unticking it hides the underlines only until that editor is made
    again. It never changes a word.
  - Link and data detection have no key; AppKit starts them off, and the writer may turn them on. They only mark text
    for display: the run codec reads no link, so nothing they add reaches the scene or the saved book (tested).
  Smart quotes and dashes, turned on, still don't change the manuscript: the character policy spells what they type
  in ASCII again, so ticking them changes nothing visible (the owner was told).
  *History:* first the editors held every automatic change off for good, with hidden menu items and overridden
  switches (PR #128). The owner rejected that as fighting the OS ("The user can toggle spelling and substitutions
  themselves from the right click menu") and chose the standard menus with off-to-start values.

## Amendment: word predictions are off for good (ADR 0049, 2026-11-09)
Inline predictions and the Touch Bar's word candidates come from Apple's language models, and the
owner wants Scene It's text never to reach one. So they are no longer the writer's to switch: every
`KeyboardTextView` reports `inlinePredictionType` `.no` and `isAutomaticTextCompletionEnabled` `false`
whatever sets them, and every other text view the focus reaches is given the same values
(`LanguageModelsOff`). No Edit-menu or context-menu item switched either of them on this macOS, so no
item had to go; System Settings' own switches no longer reach Scene It's text views. The two keys stay
registered off in `AutomaticTextChanges.startingValues`, for any text view outside Scene It's windows
(a system panel's field). Every other automatic change above is unchanged and still the writer's.
