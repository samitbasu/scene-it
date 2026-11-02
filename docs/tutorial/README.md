# Scene It tutorials

A path from Rust to Swift, SwiftUI and macOS, taught through the code of this
app. Read the chapters in order. Each one assumes the ones before it.

| # | Chapter | Status |
| --- | --- | --- |
| 00 | [Swift for Rustaceans](00-swift-for-rustaceans.md): value and reference types, protocols, errors, ARC, concurrency, macros | written |
| 01 | Project anatomy: the SwiftPM package, the Xcode app target, build settings | planned, lands with #1 |
| 02 | The model and `Codable`: `Book`, `Scene`, `Run`, strict decoding, validation | planned, lands with #7 |
| 03 | Saving safely: the `.sceneit` package, verify-then-atomic-write, backup rotation | planned, lands with #8 |
| 04 | SwiftUI and Observation: the main window, `@Observable` `BookStore`, how views track state | planned, lands with #13 |
| 05 | AppKit interop and TextKit 2: `NSViewRepresentable`, `ManuscriptTextView` | planned, lands with #15 |
| 06 | Attributed strings and the `RunCodec`: `NovelAttributes`, runs to `NSAttributedString` and back | planned, lands with #14 |
| 07 | Undo: `UndoManager`, text undo versus structural undo | planned, lands with #16 |
| 08 | The search engine: the `SearchIndex` protocol and `KeywordSearch` | planned, lands with #30 |
| 09 | Printing and export: `NSPrintOperation`, Word export | planned, lands with #35 |
| 10 | Shipping: signing, notarization, the DMG | planned, lands with #3 and #4 |
| 11 | Crash reporting: logging, MetricKit, Report a Problem | planned, lands with #12 |

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
  `// DOES NOT COMPILE` were checked to fail with the quoted error. The Rust
  blocks were built with Cargo. When the real model lands (#7), chapter 02 points
  at it, and anything in 00 that disagrees should be fixed in 00.
- **Claims about behaviour are verified, not remembered.** Where a chapter says
  what the compiler or runtime does (a diagnostic, a trap, an encoding), that was
  observed on this toolchain. Language details that depend on build settings say
  so and defer to chapter 01.

## Conventions

- Rust ↔ Swift comparisons appear side by side when the analogy helps, and the
  text says where it breaks.
- Decision records in [`docs/decisions/`](../decisions/) have short *Learning
  notes* of their own. The chapters link to them rather than repeating them.
