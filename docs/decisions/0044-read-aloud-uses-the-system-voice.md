# 0044 — Read aloud starts with the system's voice at rate 0.5

**Status:** Accepted (2026-11-09, the owner, on #38). Confirms PLAN §9 Q6's default. Amended
2026-11-09 (#39): the voice and rate are app-wide preferences, not the book's `settings`, as ADR
0022 moved them; the defaults are unchanged.

## Context
A new book needs a read-aloud voice and rate (PLAN §10.3, `settings.voice` and `settings.rate`).
The owner listened to `AVSpeechSynthesizer` samples of the system default voice (Samantha on their
Mac) at rates 0.45, 0.50 and 0.55, and of the best installed voice (a downloaded Siri voice, Nora).

## Decision
The voice and rate are app-wide preferences (`AppPreferences.readAloudVoice` and `readAloudRate`,
kept in UserDefaults), like the zoom: ADR 0022 moved the book's `settings` out of the book.
- No voice is stored at first: read aloud uses the voice chosen in System Settings › Accessibility ›
  Spoken Content (`AVSpeechSynthesisVoice(language: nil)`). A voice is stored only once the writer
  picks one.
- The rate starts at 0.5 (`AVSpeechUtteranceDefaultSpeechRate`).

## Alternatives
- **The best installed voice** (highest `quality`, falling back to the default). More natural where a
  premium voice is installed, but it differs from Mac to Mac and second-guesses the writer's own OS
  setting. A writer who prefers such a voice can set it in Spoken Content, and Scene It follows.
- **Rate 0.45 or 0.55.** Slower helps catch awkward phrasing but drags; faster skims but hides rhythm.

## Learning notes
`AVSpeechSynthesizer` synthesizes on the Mac, including with downloaded Siri voices (their assets live
under `/System/Library/AssetsV2`), so no text leaves the machine. A stored voice identifier may name
a voice another Mac doesn't have; read aloud then falls back to the system voice rather than failing.
