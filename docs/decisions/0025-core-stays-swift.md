# 0025 — The core stays in Swift for now; build a language-neutral test corpus

**Status:** Accepted (2026-11-02). Informed by [`docs/analysis/rust-core-split.md`](../analysis/rust-core-split.md).

## Decision
- `SceneItCore` stays in Swift, as PLAN §2 and ADR 0002 specified. No Rust toolchain or third-party crates are added.
- **"Step 0" anyway:** the format's test vectors become a **language-neutral corpus** (`Tests/Corpus/`): the spec's worked and
  damaged examples, the owner's demo book, the fuzz seeds, and the expected parse results as plain files. The Swift tests read the
  corpus instead of embedding the vectors, so any future second implementation (a Rust shadow codec, say) can be checked
  against the same files.
- No work is paused: search (#30), the archive (#32) and comment operations (#23) proceed in Swift as planned.
- Revisit after M2. The analysis names the triggers: wanting to review the trust-critical code in Rust, needing real coverage-guided
  fuzzing, or a non-Apple platform coming into scope.

## Alternatives (see the analysis)
A time-boxed Rust codec shadow; a Rust codec plus character rules behind the Swift API (B); Rust owning persistence too (C,
judged the wrong boundary); Rust owning the open book (E).
