# Scene It tutorials

A path from Rust to Swift, SwiftUI and macOS, taught through the code of this
app. Read the chapters in order. Each one assumes the ones before it.

| # | Chapter | Status |
| --- | --- | --- |
| 00 | [Swift for Rustaceans](00-swift-for-rustaceans.md): value and reference types, protocols, errors, ARC, concurrency, macros | written |
| 01 | [Project anatomy](01-project-anatomy.md): the SwiftPM package, the Xcode app target, build settings | written |
| 02 | [The book format](02-the-book-format.md): `book.md`, a parser that never fails, error recovery and damage locality, the character policy, the canonical serializer, round-trip properties and fuzzing | written |
| 03 | [Saving safely](03-saving-safely.md): the `.sceneit` package, verify-then-atomic-write, backup rotation, `F_FULLFSYNC`, crash states, the file-system seam, tiered snapshots and the external mirror | written |
| 03a | [When to save](03a-when-to-save.md): the autosave scheduler as a pure state machine, the `Clock` protocol, task cancellation, `@MainActor`, safe quit | written |
| 04 | [SwiftUI and Observation](04-swiftui-and-observation.md): `@Observable` and how views track state, `@MainActor` and `@concurrent`, the `BookStore` composing the trust components, `NSApplicationDelegateAdaptor`, `.commands`, `NSAlert` from async code | written |
| 05 | [AppKit interop and TextKit 2](05-appkit-interop-textkit2.md): `NSViewRepresentable` and coordinators, TextKit 2 versus 1, the text storage as a mirror of the model, delegate veto points, `typingAttributes`, the pasteboard, undo managers, field editors | written |
| 06 | [Attributed strings and the `RunCodec`](06-attributed-strings.md): `NovelAttributes`, runs to `NSAttributedString` and back | written |
| 07 | [Undo](07-undo.md): `UndoManager` versus the command pattern, grouping and coalescing, per-scene and structural histories, routing Undo to the right one | written |
| 07a | [The comments panel](07a-the-comments-panel.md): pure core types the views only show, an AppKit text view in SwiftUI with the model as the truth, a real `NSMenu` built per click, a button over a text view, `#selector` and `NSObject`'s names | written |
| 07b | [The Tags tab](07b-the-tags-tab.md): a sort and a spelling rule as pure core functions, undo inverses that restore exactly what they took on the page's manager, SwiftUI's `Layout` protocol for wrapping chips, one chip and one typing rule shared with File a Copy | written |
| 07c | [Focus mode, Esc and Tab](07c-focus-mode-and-keys.md): state that never edits the chrome, how keys reach a view (key equivalents, the first responder, the responder chain), one Esc resolver with many entrances, a forwarding delegate, `@FocusState` and `onKeyPress` | written |
| 07d | [Export as SceneIt](07d-export-as-sceneit.md): a type whose only constructor is a projection, one parser serving two grammars, a verified write outside the package, `NSSavePanel` from SwiftUI behind a seam, a sheet bound to model state, Shift-click in a `Toggle` | written |
| 07e | [The Scenes sheet](07e-the-scenes-sheet.md): pure card functions in core, `LazyVGrid` and adaptive columns, a ticker with an injected clock that keeps ages current, AppKit fields that take the focus as they appear, an undo inverse that keeps words, one + tag field shared with the Tags tab; moving, cutting and restoring as pure index arithmetic, `onDrag` and `DropDelegate` with a private `UTType`, keys on the sheet's focus view | written |
| 08 | [The search engine](08-search-engine.md): search units as `Sendable` snapshots, the `SearchIndex` protocol as a trait object, `AsyncSequence` versus Rust's `Stream`, cooperative cancellation, words and endings, ranking as one comparison, near matches, the Search sheet's one task per query | written |
| 09 | Printing and export: `NSPrintOperation`, Word export | planned, lands with #35 |
| 10 | [Shipping](10-shipping.md): certificates and identities, Developer ID, the hardened runtime, timestamps, notarization and stapling, Gatekeeper, the DMG, dSYMs | written |
| 11 | [Crash reporting](11-crash-reporting.md): logging, MetricKit, Report a Problem | written |

Chapter 06 follows 05 in reading order even if #14 merges first. Read 06 after 05.

## How the chapters stay honest

A tutorial that paraphrases code drifts from it. These rules prevent that:

- **Every chapter from 01 on is anchored in real code.** It links the files it
  teaches from (for example `Sources/SceneItCore/Model/Scene.swift`), and its
  snippets are excerpts of those files, not re-typed lookalikes. The chapter
  lands in the same PR as the code it describes. That PR is the "lands with #N"
  in the table above.
- **A PR that changes an anchored file updates the chapter** that quotes it.
  Reviewers check this, the same way they check tests (see
  [WORKFLOW.md](../dev/WORKFLOW.md), step 5).
- **Chapter 00 predates the code,** so it uses the model sketch in PLAN §5.3.
  Instead of anchors, its snippets were extracted and compiled. Every Swift block
  was built with Swift 6.4 in a scratch package. Blocks marked
  `// DOES NOT COMPILE` were checked to fail with the quoted error. When the
  real model lands (#7), chapter 02 points
  at it, and anything in 00 that disagrees should be fixed in 00.
- **Claims about behaviour are verified, not remembered.** Where a chapter says
  what the compiler or runtime does (a diagnostic, a trap, an encoding), that was
  observed on this toolchain. Where behaviour depends on build settings, the
  chapter says so and links the decision record that fixes the setting.

## Conventions

- Rust ↔ Swift comparisons are given where the analogy helps, and the text says
  where it breaks.
- Decision records in [`docs/decisions/`](../decisions/) have short *Learning
  notes* of their own. The chapters link to them rather than repeating them.
