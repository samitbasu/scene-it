# Engineering practices

These practices are project-agnostic. They travel with me between repositories;
project-specific notes live in the final section, which you can delete when
copying this file elsewhere.

## Design philosophy

1. **Prefer the simplest design that exploits the problem's invariants.**
   Before designing for the general case, identify the invariant that makes the
   common case cheap (e.g. "the routing graph is fixed while a gesture is in
   progress — cache the router per gesture" beats an incremental graph
   migration). When a plan is getting large, stop and check whether a simpler
   observation collapses it.
2. **"Simple" means no over-engineering — it does not mean avoiding
   complexity or abstraction.** Sharp tools (higher-ranked trait bounds,
   advanced generics) are permitted, but they are sharp: each use needs a
   justification. Speculative machinery for problems we don't have yet is
   over-engineering; a well-chosen abstraction for a problem we do have is not.
3. **Fix the API, don't work around it.** If a new feature is awkward because
   of the current API's shape, spike and rework the API first. Work-arounds are
   fragile, accumulate as rot, and the rework is an opportunity to reconsider
   the structure. (A per-feature fallback that patched around a missing input
   model lived exactly one day before the model grew the missing concept and
   the fallback was deleted — build the concept first.)
4. **Tech debt is a real concern.** A forked or parallel implementation of
   anything *will* diverge from its sibling and generate issues downstream.
   Treat duplication and drift as costs on par with bugs.

## DRY and shared functionality

- **Copy-paste is to be avoided wherever possible.** Parallel implementations
  that must be updated in lockstep are silent-drift hazards.
- The preference ladder for sharing functionality:
  **pure functions → helper functions → methods on structs/enums → macros
  (last resort).** All of these beat pasting the logic again.
- Policy that several call sites must agree on (a hit-test priority order, a
  z-order, a dispatch sequence) should be **encoded once** — as data or a
  single resolver — and consumed everywhere, so the sites cannot disagree.
- **External crates are preferred to reproducing their functionality in-app.**
  If a library we already depend on computes the thing (e.g. the UI toolkit's
  text-layout engine), consume its output rather than approximating it —
  even at modest integration cost — because the in-house approximation will
  drift.

## The type system encodes invariants

- **Illegal states should be unrepresentable.** Mutually exclusive application
  modes are one enum, not N `Option`/`bool` fields. A press-with-origin is
  `Option<Press { origin }>`, never `pointer_down: bool` + `origin:
  Option<_>` which can disagree.
- **No naked `bool` arguments.** Use a two-variant enum or a typed wrapper
  that names the meaning at the call site.
- **No naked `f32`/`f64` arguments.** A bare float in a signature carries no
  meaning. Wrap it in a newtype naming the semantic (`Zoom`, `Progress`,
  `WorldDistance`): constructor to wrap, `impl From<Newtype> for f32` so callees
  extract via `Into`. If the value is *constrained* (non-negative, unit
  interval), it stays wrapped everywhere and the newtype enforces the
  constraint — clamping constructors, saturating ops implemented once on
  `std::ops` impls (never re-clamped at call sites), NaN handled so ordering
  is total.
- **Durations are `core::time::Duration`. Always.** Convert to float seconds
  only at foreign API boundaries. This makes negative durations and unit
  confusion unrepresentable, and deletes their guard code.
- Prefer typed enums with `Into` impls over threading primitives through
  layers.

## Comments

- Follow the clean-code principle: **comment only surprising or unexpected
  behavior.** Never narrate what the code does, where a change came from, or
  why a change is correct — that is reviewer-talk, noise once merged.
- If a function needs a comment to be understood, that is refactoring
  pressure, not documentation debt. **Heavily commented code is a warning to
  the reader that it requires extra thought** — restructure until the comment
  is unnecessary.
- Prefer names and types that make intent clear; comments drift, names and
  types do not.
- Data structures are commented only when part of a public API or when their
  intent is non-obvious.

## Dependencies

- Before building a feature on a deprecated or outdated API, **migrate the
  dependency to its latest version first**, then build on the current API.
  Building on the old surface doubles the eventual migration.

## Testing and verification

- A test must **prove** what it claims: if it depends on a geometric or
  structural precondition (two rects overlap, a target exists), assert the
  precondition inside the test so it can't silently stop testing anything.
- Verify UI behavior **through the full real path** (dispatch, tool switching,
  event flow), not only through isolated component tests — isolated tests can
  pass while the integrated path misbehaves.
- Refactors declared behavior-preserving must not change any test outcome.
  Behavior *changes* are enumerated explicitly (what, where, why) at review
  time, never discovered later.
- Golden/regression tests guard end-to-end behavior; regenerating a golden is
  an acceptance step whose diff gets reviewed, not a chore to silence.
- Zero clippy warnings; new code lands with its tests.

## Developer-facing tooling

- For author/dev tooling, prefer the console and an edit-and-re-run loop over
  in-app UI (transport controls, guards, on-screen error panes). Print errors
  where the developer already is; keep flags few and composable.
- Errors that point at a file should carry spans and render with the source
  attached (e.g. miette-style reports), not stringly byte offsets.

## Workflow conventions

- Commit messages explain the *why* and the shape of the change; intentional
  behavior changes are listed in the message.
- Breaking changes are acceptable while a project is undeployed, in the name
  of simplification — note them clearly.
- **Aesthetic choices are the user's.** Icons, colours, layout, spacing,
  typography, wording on screen — anything about how the app looks or
  reads — are run past the user before they land, never decided on their
  behalf. Where there are candidates, show all of them (rendered, at the
  size they will be used, beside what surrounds them), give a
  recommendation, and wait for the pick.

---

# Project: Scene It

macOS novel-writing app (Swift 6, SwiftUI + AppKit TextKit 2). These notes are project-specific.

- **Start here when resuming:** `docs/dev/WORKFLOW.md`. Work is tracked as GitHub issues and milestones (`gh issue list`).
- **Spec:** `novel-app-build-bundle/PLAN.md`. **Deviations and decisions:** `docs/decisions/` (they override PLAN).
- **Gate:** `scripts/check.sh` must pass before any commit lands on `main`.
- **Scripts are documented in `README.md`** (usage, example arguments, outputs). Any PR that adds or changes a script updates that section.
- **Layout:** `SceneItCore` SwiftPM package (model, persistence, backups, archive, search, reporting) under `Package.swift`/`Sources`/`Tests`; thin app target in `SceneIt/` (synchronized folders, so never hand-edit the pbxproj to add files).
- **Swift translation of the rules above:** no naked `Bool` parameters (use two-case enums); no naked `Double`/`Float`/`CGFloat` parameters in our APIs (use newtypes such as `Zoom` and `SpeechRate`); `Duration` for time spans; illegal states unrepresentable. The JSON format (PLAN §5) is a contract; the in-memory model may be richer, with `Codable` mapping to the exact JSON.
- **Trust first:** data-loss prevention beats performance. See the trust rules in WORKFLOW.md.
- **Ask the owner** on anything labelled `decision` or `aesthetic`. They want decision points as learning opportunities, so present the alternatives with trade-offs.
- **Tutorials:** `docs/tutorial/` explains the app to a seasoned Rust programmer new to Swift/SwiftUI/macOS. Keep it current as features land.
