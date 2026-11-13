# 0044 — Read aloud starts with the system's voice at rate 0.5

**Status:** Accepted (2026-11-09, the owner, on #38). Confirms PLAN §9 Q6's default. Amended
2026-11-09 (#39): the voice and rate are app-wide preferences, not the book's `settings`, as ADR
0022 moved them; the defaults are unchanged. Corrected 2026-11-13: Siri voices weren't offered to
Scene It, while Ava (Premium) was (see Correction).

## Context
A new book needs a read-aloud voice and rate (PLAN §10.3, `settings.voice` and `settings.rate`).
The owner listened to `AVSpeechSynthesizer` samples of the system default voice (Samantha on their
Mac) at rates 0.45, 0.50 and 0.55, and of the best installed voice (a downloaded Siri voice, Nora).
The Nora sample was made through Apple's `swift` tool, which can use Siri voices; Scene It can't
(see Correction).

## Decision
The voice and rate are app-wide preferences (`AppPreferences.readAloudVoice` and `readAloudRate`,
kept in UserDefaults), like the zoom: ADR 0022 moved the book's `settings` out of the book.
- No voice is stored at first: read aloud uses the voice chosen in System Settings › Accessibility ›
  Spoken Content (`AVSpeechSynthesisVoice(language: nil)`), except a Siri voice (see Correction).
  A voice is stored only once the writer picks one.
- The rate starts at 0.5 (`AVSpeechUtteranceDefaultSpeechRate`).

## Alternatives
- **The best installed voice** (highest `quality`, falling back to the default). More natural where a
  premium voice is installed, but it differs from Mac to Mac and second-guesses the writer's own OS
  setting. A writer who prefers such a voice can set it in Spoken Content, and Scene It follows (a
  Premium voice, not a Siri one; see Correction).
- **Rate 0.45 or 0.55.** Slower helps catch awkward phrasing but drags; faster skims but hides rhythm.

## Learning notes
`AVSpeechSynthesizer` synthesizes on the Mac, so no text leaves the machine. A stored voice
identifier may name a voice another Mac doesn't have; read aloud then falls back to the system voice
rather than failing.

## Correction (2026-11-13)
**Siri voices weren't offered to Scene It.** The Siri voices are Spoken Content's "Voice 1–5"
(`com.apple.siri.natural.*`). In every process we tried except Apple's `swift` tool, they weren't
offered: Scene It's own process (the test host), and small programs of our own, unsigned or ad-hoc
signed with the hardened runtime. We didn't test a Developer ID-signed, notarized build, and we don't
know why macOS holds them back. In those processes:
- `AVSpeechSynthesisVoice.speechVoices()` leaves them out;
- `AVSpeechSynthesisVoice(identifier: "com.apple.siri.natural.Nora")` returns `nil`;
- with a Siri voice as the System voice, `AVSpeechSynthesisVoice(language: nil)` returns the
  language's standard voice (Samantha for en-US, on this Mac).

The same code run through Apple's `swift` tool sees them, which is how the Nora sample above was
made. The owner's other Mac, with Voice 4 as the System voice, read aloud in Samantha.

**Ava (Premium) worked.** With Ava (Premium) as the System voice, six fresh processes of such a
program each got `com.apple.voice.premium.en-US.Ava` from `language: nil`, both before and after
listing the voices. Other Premium voices should behave the same; Enhanced voices weren't tested. A
writer who wants a natural voice downloads one in System Settings › Accessibility › Spoken Content ›
System voice › Manage Voices… and makes it the System voice, and Scene It should follow it.

**Lesson:** a sample offered for a decision must be made the way the app makes it, by the app or a
program of our own. Apple's command-line tools can see more than the app can.
