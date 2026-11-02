# 0003 — Minimum macOS 26

**Status:** Accepted (2026-11-01). **Deviates from PLAN** (macOS 14+, Q3).

## Decision
The deployment target is macOS 26.

## Why
- The development Mac runs macOS 27, so nothing older can be tested here.
- TextKit 2 had notable bugs in 14/15.
- "Make crashes rare" outweighs reaching writers on older Macs.

## Consequences
- We may use APIs up to macOS 26 without `#available` checks.
- Writers on 14/15 can't run the app. Revisit this if a tester needs it.

## Learning notes
The *deployment target* is the oldest OS the binary will load on. The *SDK*
(set by the Xcode version) decides which APIs you can name. Calling an API newer
than the deployment target needs an `if #available(macOS 27, *)` guard. That's a
compile-time-checked runtime branch, a little like `cfg` but evaluated at runtime.
