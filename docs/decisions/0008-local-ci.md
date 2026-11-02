# 0008 — Local check script instead of hosted CI

**Status:** Accepted (2026-11-01)

`scripts/check.sh` is the gate for every commit and PR, whether made by agents or
humans. It runs `swift format lint --strict`, `swift test`, and `xcodebuild build
test` with warnings treated as errors. Hosted CI can run the same script later.
