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
| [0009](0009-report-destination.md) | Problem reports go to the owner's personal email | Accepted — resolves #6 |
| [0010](0010-nonnegative-interval.md) | Time spans use a non-negative `Interval` newtype over `Duration` | Accepted — Swift caveat to CLAUDE.md |
| [0011](0011-mainactor-default-isolation.md) | App target defaults to `@MainActor` isolation | Accepted |
| [0012](0012-model-type-names.md) | Model types renamed: `BookScene`, `BookSettings`, `SceneTextPart` | Accepted |
| [0013](0013-black-means-no-color.md) | `"color": "black"` loads as no color; the encoder never writes it | Accepted — refines PLAN §5.2/§6.2 |
| [0014](0014-title-always-bold.md) | Scene titles are always bold; Bold is disabled in the title | Superseded by 0015 |
| [0015](0015-title-is-a-plain-field.md) | Title is a plain-text field above the page, not part of the page text | Accepted — deviates from PLAN §6.1 |
| [0016](0016-text-only-no-images.md) | Text only; the editors refuse images | Accepted |
| [0017](0017-paste-carries-comments.md) | Pasting commented text copies its comments into the destination scene | Accepted |
