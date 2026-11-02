# 0010 — Time spans use a non-negative newtype over `Duration`

**Status:** Accepted (2026-11-01). Adds a Swift caveat to CLAUDE.md's rule "Durations are `core::time::Duration`. Always."

## Problem
CLAUDE.md requires `Duration` partly because Rust's `core::time::Duration` can't be negative.
Swift's `Duration` is **signed**: `Duration.seconds(-1)` compiles and compares `< .zero`.
In Swift, using `Duration` alone doesn't give that guarantee.

## Decision
`SceneItCore` defines one newtype for every span our APIs accept (autosave delays,
backup tiers, report windows):

```swift
public struct Interval: Hashable, Comparable, Sendable {
    public let duration: Duration          // invariant: >= .zero
    public init(clamping: Duration)        // negative → .zero
    // + and saturating - implemented once; .seconds/.minutes/.hours conveniences
}
```
`Duration` stays the currency type at foreign API boundaries (`Task.sleep`, `ContinuousClock`).
Converting to `Duration` is free, and converting from it clamps exactly once.

## Alternatives
- Plain `Duration` with `>= .zero` guards: the invariant lives in runtime checks at each call site.
- Plain `Duration` with no guards: the weakest guarantee.

## Learning notes
This is CLAUDE.md's constrained-newtype rule (like `Zoom`) applied to time. In
Rust the standard library did this for you; in Swift you write the 30 lines yourself, once.
