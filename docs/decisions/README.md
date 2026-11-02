# Decision log

One file per decision, ADR-style. Each records what was chosen, the alternatives,
and *why* — plus a "Learning notes" section aimed at a Rust programmer new to
the Apple platform. Pending decisions are GitHub issues labelled `decision`;
when one is resolved, it gets a file here and the issue is closed with a link.

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-distribution-developer-id.md) | Distribute with Developer ID + notarization | Accepted |
| [0002](0002-project-structure.md) | Xcode app target + local SwiftPM package `SceneItCore` | Accepted |
| [0003](0003-minimum-macos-26.md) | Minimum macOS 26 (plan said 14) | Accepted — deviates from PLAN |
| [0004](0004-book-is-a-package.md) | A book is a `.sceneit` package | Accepted — deviates from PLAN §5.1 |
| [0005](0005-backups.md) | Backups: bak1–3 + tiered snapshots + external mirror | Accepted — extends PLAN §5.4 |
| [0006](0006-crash-reporting.md) | Built-in "Report a Problem", Apple frameworks only | Accepted |
| [0007](0007-name-and-bundle-id.md) | "Scene It", `com.samitbasu.SceneIt` | Accepted — resolves PLAN Q2 |
| [0008](0008-local-ci.md) | Local `scripts/check.sh` instead of hosted CI | Accepted |
