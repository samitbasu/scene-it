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
| [0018](0018-external-change-ux.md) | External change on disk: ask Keep Mine / Open Theirs; both versions survive | Accepted |
| [0019](0019-backup-failure-policy.md) | Backup can't be written: refuse for external versions, save-and-warn for our own | Accepted |
| [0020](0020-instance-and-book-locks.md) | One app instance (flock) and one writer per book; the second opener gets read-only | Accepted |
| [0021](0021-one-book-at-a-time.md) | One book open at a time; switching books saves and closes the current one first | Accepted |
| [0022](0022-markdown-book-format.md) | Book format v2: tolerant Markdown (`book.md`), Latin-1, marks, Errors tab; settings move to app prefs | Accepted — replaces PLAN §5 |
| [0023](0023-word-count-like-word.md) | Word counts match Microsoft Word (whitespace-delimited, body only) | Accepted |
| [0024](0024-damaged-books-open-read-only.md) | A book repaired on open is read-only until the writer chooses Make Editable; the original is kept permanently | Accepted |
| [0025](0025-core-stays-swift.md) | Core stays in Swift; language-neutral test corpus; revisit after M2 | Accepted |
| [0026](0026-crash-on-exceptions.md) | Crash cleanly on uncaught ObjC exceptions (NSApplicationCrashOnExceptions) | Accepted |
| [0027](0027-color-shortcuts.md) | Text color shortcuts are Ctrl+Cmd+1…7; Cmd+1 stays Scenes | Accepted — resolves PLAN Q4 |
| [0028](0028-strict-ascii-no-input-methods.md) | Strict ASCII text with input methods disabled; a transliteration table for everything else | Accepted — supersedes 0022 §Characters |
| [0029](0029-review-round-trip.md) | Review round trip: Export as SceneIt, Review Book, Copy/Save Review | Accepted — new feature |
| [0030](0030-text-height-caret.md) | A text-height caret on the double-spaced page: our own `NSTextInsertionIndicator`, the system caret clear | Superseded by 0034 |
| [0031](0031-boneyard-delete-hides.md) | Deleting from the Boneyard hides the scene in a Deleted section of book.md; restore by hand | Accepted — resolves PLAN Q7 |
| [0032](0032-comment-underlines-stack.md) | Commented text gets stacked colored underlines, one per comment | Accepted — resolves PLAN Q1 |
| [0033](0033-search-matching-rules.md) | Search: Whole word keeps the possessive, contractions stay whole, tags are single-line and one per line, punctuation goes to the find bar | Accepted — refines PLAN §9.2 |
| [0034](0034-double-spacing-below-the-line.md) | Double spacing below the line (`lineSpacing`, the text a gap lower), so the system caret and selection are text height | Accepted — supersedes 0030; deviates from PLAN §6.1 |
| [0035](0035-comments-on-the-manuscript-only.md) | Comments are on the manuscript only: the notes draw none, and paste into them drops comments | Accepted — narrows 0017; deviates from PLAN §8.6 |
| [0036](0036-no-drag-and-drop-of-text.md) | No drag and drop of text: the manuscript editors and fields refuse drops and never start a drag | Accepted — amends 0016 and 0028 on drops |
| [0037](0037-comment-operations.md) | Comment operations: the page changes the text, the store changes the list; New Comment is Cmd+Shift+M | Accepted — deviates from PLAN §8.1 and §11 |
