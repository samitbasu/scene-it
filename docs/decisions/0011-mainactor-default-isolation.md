# 0011 — App target defaults to `@MainActor` isolation

**Status:** Accepted (2026-11-01)

## Decision
- **App and app-test targets:** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
  `SWIFT_APPROACHABLE_CONCURRENCY = YES`. UI code is main-thread by default. Background
  work (search scans, decoding filed copies, zipping reports) is opted out explicitly
  with `nonisolated` / `@concurrent`, so every place concurrency happens is visible.
- **`SceneItCore` package:** plain Swift 6 defaults (no default isolation). It's pure
  logic, and types that need the main actor, such as `BookStore`, say `@MainActor` explicitly.

## Alternatives
Plain Swift 6 everywhere: every UI type needs `@MainActor` by hand, and
`nonisolated async` functions silently run on the global executor.

## Learning notes
Rust has no default executor or thread affinity. Swift lets a module declare "everything
here is confined to the main actor unless it says otherwise", which is roughly a crate-wide
`!Send` with explicit escape hatches. AppKit and SwiftUI are main-thread APIs,
so this default matches reality and removes a lot of annotation noise.
