# Analysis: a Rust core under a Swift UI?

**Status:** Analysis for the owner's decision (2026-11-02). Changes nothing. If the owner picks
an option other than A, record the choice as an ADR: it reverses PLAN §2's "Swift, Apple SDKs
only" and README rule 3, "No third-party dependencies without asking first".

> **Note (2026-11-03):** ADR 0028 (strict ASCII, #74) has since removed NFC and the Latin-1 repertoire:
> the character policy is a versioned transliteration table, data with no Foundation dependency,
> and search folds case only. The NFC, `unicode-normalization` and diacritic-folding points below
> describe the code as it was when this was written.

**The question.** "We seem to have quite a bit of business logic in Swift. I'm curious about a
language split: the business logic and backend in Rust, the UI in Swift/SwiftUI."

## Executive summary

**The business logic in Swift is the original cut, but it has grown.** PLAN §2–§3 and
[ADR 0002](../decisions/0002-project-structure.md) put the model, codec, store, persistence,
backups and search in `SceneItCore`, a Swift package meant to be "like a Rust lib crate". Rust
appears only once, as a possible future *search* backend (PLAN §9.2: "tantivy via UniFFI"). The
growth came from the trust decisions (ADRs 0005, 0018–0020, 0022, 0024). PLAN's "atomic write
plus `bak1…3`" is now 2,963 lines of persistence: snapshots, a mirror, locks, a stray-file
sweep, external-change detection and repair-on-open. Over two days `SceneItCore` reached
**9,612 lines of code and 10,261 lines of tests**. The app target is 1,286 lines.

**About 40% of `SceneItCore` could move to Rust cleanly.** That's the pure code: the format codec,
the character policy, the model values, word counting, the snapshot schedule and the autosave
state machine. About 30% is OS integration that Rust *can* do, at the cost of `unsafe` FFI or
extra crates: POSIX file I/O, `flock`, `renamex_np`, volume capabilities, the computer name,
SHA-256. The remaining 30% has to stay in Swift: `@Observable` stores, AppKit text attributes,
`os.Logger` and `OSLogStore`, MetricKit, `UserDefaults`, and every string the writer reads.
Almost all the work left in M2–M6 is in that last group: the TextKit 2 editor, comment drawing,
sheets, print, Word export and read aloud.

**The spike worked, and showed real friction.** This toolchain has Rust 1.98, Swift 6.4.2 and
Xcode 27.2. I exported Rust through UniFFI 0.32.2 as a static library inside an XCFramework,
consumed it as a SwiftPM `binaryTarget`, and called it from Swift Testing under Swift 6 mode with
warnings as errors. The generated Swift compiled cleanly. Moving a whole book across the boundary
takes about 1.5 ms each way, against the existing Swift codec's 27 ms parse. A call costs about
1 µs, which is fine even once per keystroke. The friction:

- Generated signatures use untyped `throws`, so Scene It's typed throws is lost at the boundary.
- Cancelling a Swift `Task` doesn't cancel the Rust future.
- A panic in a non-throwing function hits `try!` and becomes a Swift trap, with the panic message
  in it. That conflicts with the repo's "static trap messages" guard.
- The generated Swift is 1,481 lines and produces 1,216 `swift format` findings, so it must be
  excluded from lint and the guards.
- Crash reports get Rust file and line, but `atos` doesn't demangle Rust names.
- The x86_64 Rust target isn't installed here. Release builds are universal, so it would be
  required.

**What Rust would buy.** Mostly *reviewability by the owner*: Rust is the language you read most
fluently. It would also bring real fuzzing (cargo-fuzz/libFuzzer; Swift's `-sanitize=fuzzer` is
unsupported on this macOS toolchain, which I checked), mature proptest, and Miri. **What it
would cost.** A second toolchain, a build-order dependency, about 30 third-party crates, and a
boundary where Swift's compile-time invariants become runtime checks: `~Copyable` tokens,
policy-enforcing `didSet`, typed throws. There's also one real drift hazard. The character policy
runs in the editor on every keystroke and in the parser on every file, so it must have exactly one
implementation. It already depends on Foundation's NFC tables and Swift's `Character.isLineBreak`,
and a Rust port would bring its own tables.

**Recommendation (moderate confidence).** Keep option **A** (all Swift) for now. Make the
format's test vectors language-neutral, which is useful whatever you decide. If the curiosity is
strong, the right experiment is **B's first step**: a *test-only* Rust codec, written from the
spec and run differentially against the Swift one, with a decision date fixed in advance (promote
it or delete it). **Don't choose C:** it splits the autosave scheduler from the model it must
snapshot "in the same main-actor turn". Defer **E** (Rust owns the open book) until the editor
exists. #15 can proceed under every option. Pause only the new *core* logic whose language is now
open: #30 search, #32 archive reconciliation, and #23's model operations.

---

## 1. Inventory

Measured with `wc -l` on `origin/main` at `b571b4b`. "Tests" counts `Tests/SceneItCoreTests/<area>`.
Imports are the file headers.

| Area | Code | Tests | Apple dependencies | Kind |
| --- | ---: | ---: | --- | --- |
| **Format** (parser, serializer, inline, entries, archive index format) | 2,081 | 2,323 + 15.7 KB fixtures | Foundation `Data` only | Pure business logic |
| **Model** (Book, BookScene, Run, Paragraph, ids, palette, CharacterPolicy, Timestamp, Bounded) | 1,041 | 419 | Foundation: `Date`/`TimeZone` (Timestamp), NFC via `precomposedStringWithCanonicalMapping` (CharacterPolicy) | Pure, but the policy depends on Unicode tables (see §4.3) |
| **Text**: `WordCount` | 90 | (in 374) | none | Pure |
| **Text**: `RunCodec`, `NovelAttributes`, `ParagraphRole`, `PaletteSwatches` | 356 | 374 | **AppKit**: `NSAttributedString`, `NSFont` traits, `NSColor`, `@MainActor` | UI glue, Apple-side by nature |
| **Persistence**: `SnapshotSchedule`, `PackageLayout`, `UTCStamp`, errors | 440 | (in 4,219) | Foundation `URL`/`Date` | Pure |
| **Persistence**: `FileSystem` seam, `LocalFileSystem`, `ExclusiveFileLock`, `LockRecord` | 895 | (in 4,219) | POSIX (`open` with `O_CLOEXEC`/`O_NOFOLLOW`, `F_FULLFSYNC`, `renamex_np(RENAME_SWAP)`, `chflags`, `flock`, `kill(pid,0)`, `gethostuuid`), `URLResourceValues` (volume UUID, `volumeIsLocal`, swap/exclusive-rename support), **SystemConfiguration** (`SCDynamicStoreCopyComputerName`) | OS integration (Rust can do it with `libc`/`rustix` and some hand FFI) |
| **Persistence**: `BookPackage`, `BackupKeeper`, `StrayTemporaryFiles` | 1,531 | (in 4,219) | **CryptoKit** (`SHA256` for `ContentDigest`), `Synchronization.Mutex`, `JSONEncoder` (backup metadata), `~Copyable` tokens (`KeptOriginal`, `EditingLock`, `LockAttempt`) | Business logic over the seam |
| **Persistence**: `ReadOnlyWording` | 97 | — | Foundation | Writer-facing wording, Swift-side |
| **Autosave**: `AutosaveScheduler`, `QuitDecision` | 339 | 861 (with the driver) | none (generic over `Instant`) | Pure state machine |
| **Autosave**: `AutosaveDriver`, `QuitWording` | 240 | — | **Observation** (`@Observable`), `@MainActor`, `Clock`/`Task` timers, `CheckedContinuation` | Concurrency glue, Swift-side |
| **Store**: `BookStore`, `OpenBook`, `BookStatus`, `StorePrompts`, `StoreWording`, `RecentBooks` | 971 | 1,233 | **Observation**, `@MainActor`, `UndoManager`, `UserDefaults`, async alerts | App state and orchestration, Swift-side |
| **Store**: `BookWriter` | 141 | — | `Mutex`, off-main-actor saves | Glue between the store and persistence |
| **Diagnostics** (Log, LogRing, ProblemReport, SessionMarker, payloads) | 900 | 476 | **os.Logger**, **OSLogStore**, MetricKit payload files, `FileManager`, zip | OS integration, Swift-side |
| **Launch** (`LaunchGate`, the instance lock) | 119 | 105 | `flock`, `ProcessInfo` | OS integration |
| **Window** (prefs, scene location, wording) | 300 | 200 | **UserDefaults**, Observation | UI state, Swift-side |
| **Foundation** (`Interval`, `CanonicalPath`) | 67 | 43 | Foundation | Pure helpers |
| **Totals, `SceneItCore`** | **9,612** | **10,261** | | |
| App target `SceneIt/` (+ `SceneItTests/`) | 1,286 | 876 | SwiftUI, AppKit, MetricKit subscriber | UI |

No file uses `NSFileCoordinator`. Persistence goes through the hand-written `FileSystem` seam,
which the tests replace with `FaultInjectingFileSystem`. It fails chosen calls, or "crashes" in
the middle of a write.

### What could move, by kind

| | Lines (code) | Examples | Rust would need |
| --- | ---: | --- | --- |
| **Moves cleanly** (pure) | ~4,050 | Format, Model values, CharacterPolicy, WordCount, SnapshotSchedule, AutosaveScheduler, QuitDecision, PackageLayout, Interval | `unicode-normalization` (NFC). For `Timestamp`, either a time-zone crate (`jiff`) or the UTC offset passed in from Swift |
| **Could move, with OS FFI** | ~2,500 | LocalFileSystem, locks, LockRecord, BookPackage, BackupKeeper, stray sweep | `libc`/`rustix` (`F_FULLFSYNC`, `renamex_np`, `flock`, `chflags`), hand FFI for `getattrlist` volume capabilities and `SCDynamicStoreCopyComputerName` (or Swift passes the name in), `sha2` |
| **Apple-side by nature** | ~3,000 | RunCodec/NovelAttributes (AppKit), `@Observable` Store/OpenBook/AutosaveDriver, Diagnostics (OSLog/MetricKit), prefs (`UserDefaults`), ~600 lines of `*Wording` (text the writer reads) | — |

The work left in the plan has a similar spread. M2–M6 are mostly Apple-side: #15 the TextKit 2
editor, #24 underline drawing, the #28/#31/#33 sheets, #35 print, #37 Word export, #39 read
aloud. The new *core* logic is #30 search (PLAN §9.2), #23 comment operations, #32 archive
reconciliation, and the Errors tab model behind #63.

## 2. Boundary options

The numbers in this section come from the spike in §6. Moving a 120k-word book (700 KB, 60
scenes, 1,200 paragraphs) across UniFFI costs **~1.4 ms** for the bytes (a copy into a
`RustBuffer`), **~1.5 ms** to bring the parsed tree back into Swift, and **~0.7 ms** to send a
tree to Rust and serialize it. A small call costs **~1.1 µs** (**~30 ns** through a hand-written
C ABI). The existing Swift codec takes 27 ms to parse that book, 12 ms to serialize it and 50 ms
for a verified save (release build). **Marshalling cost decides none of the options.** Ownership,
invariants and drift decide them.

### Summary table

| | A: status quo | B: Rust codec + policy (+ search) | C: B + persistence + autosave | D: Rust for new engines only (search pilot) | E: Rust owns the open book |
| --- | --- | --- | --- | --- | --- |
| **What's in Rust** | nothing | parse/serialize/verify, CharacterPolicy, model values, word count, archive-index format; later search | B + package, save/rotate/snapshot/mirror, sweep, locks, autosave scheduling | search (#30), maybe later engines | C + every edit command (scene ops, comments, Boneyard), search, archive |
| **What crosses** | — | bytes ↔ `Book` per load/save; `admit` per keystroke/paste; runs per editor debounce | B + save requests and outcomes, status callbacks, lock and repair tokens | search units in (per search or incrementally), hits out, progressively | edit commands per debounce, snapshots/projections for views, status callbacks |
| **Frequency** | — | load: once; save: ≤ every 2 s; admit: per keystroke (~1 µs) | B + timer events and callbacks to the main actor | per query | per edit, plus view refreshes |
| **Rewrite** (code / tests) | 0 | ~3.2k / ~2.8k | ~6.6k / ~8k | 0 rewritten; ~1.5–2.5k new | ~7.5k / ~9k, plus every future model feature |
| **Swift invariants kept** | all | model invariants become boundary checks (custom types); typed throws lost at the binding layer | B + `~Copyable` tokens become runtime "taken" checks; main-actor-turn atomicity becomes a cross-thread protocol | all of them in Swift; search code gets Rust's | most move into Rust, where they're stronger; Swift views see projections |
| **Drift risk** | none | the policy must exist only in Rust; RunCodec's paragraph splitting must match | B + Swift fault-injection tests must reach Rust's file system | the search tokenizer must match the parser's notion of words and paragraphs | the lowest once complete; during migration the highest |
| **Fit with the owner's motivation** | Swift learning continues | trust-critical parser in your best language | the most "backend in Rust" | lowest-risk way to learn the toolchain | the cleanest architecture in the end, the most work now |
| **Verdict** | **recommended for now** | **the candidate if you want Rust**; do it shadow-first | **not recommended** (the wrong seam) | viable pilot, but tests the least important thing | revisit after M2 |

### A — status quo: everything in Swift

Nothing crosses a language boundary. Every existing safety property stays as it is: typed throws
on every persistence API, `~Copyable` proofs (`KeptOriginal` must be consumed by `edit`, and
`ExclusiveFileLock` is released by `deinit`), the policy-enforcing `didSet` on `Run.text`,
`Book.title` and the rest, and the main-actor-turn rule for autosave.

Costs. You review trust-critical code in your second language. Swift on macOS has no
coverage-guided fuzzer (§4.1), so `FuzzTests.swift` uses seeded random loops (3,000 rounds per
property) rather than libFuzzer. The `SearchIndex` protocol keeps tantivy possible later.

### B — a Rust codec and character policy (and later search)

**In Rust:** `parse(bytes) -> ParsedBook` (total, with no `Result`), `serialize(&Book) -> Vec<u8>`,
`verified_serialization(&Book) -> Result<Vec<u8>, VerifyError>`, the archive-index format,
`admit`/`admitted`/`admitted_line`, `WordCount`, and the model *values* (`Book`, `BookScene`,
`Paragraph`, `Run`, `Comment`, `ErrorEntry`, ids, palette). **In Swift:** everything else,
including persistence, which calls the Rust serialize, verify and parse.

**What crosses, and how often.** A load sends the bytes in and brings a `Book` record tree back
(~3 ms for a long novel). A save sends a `Book` in and gets bytes back (~1 ms). The editor calls
`admit` on typing and pasting (~1 µs a call), and #15's debounced `RunCodec` produces `Paragraph`s.
If those are generated records, building them costs nothing. Every `Run(...)` that applies the
policy is one FFI call: about 0.7 ms for a 600-run scene, or batch it.

**The model's shape is the hard part.** UniFFI records arrive in Swift as generated structs with
a public memberwise initializer. Today's `didSet { text = CharacterPolicy.admittedLine(text) }`
can't be expressed on a generated struct. There are three ways to keep "a run can't hold what
book.md can't store":

1. **Custom types.** Wrap the text in an `AdmittedLine` newtype on the Rust side with
   `uniffi::custom_type!`. The Rust side applies the policy whenever the value enters Rust, which
   enforces it at the boundary rather than in Swift's type system. `uniffi.toml` can map it to a
   Swift wrapper whose `init` calls Rust's `admit`, so construction stays checked.
2. **Hand-written Swift model mirrored from the records.** This brings back the duplication
   CLAUDE.md warns about.
3. **Opaque handles.** That's option E.

Option 1 is the honest version of B.

**Threading.** UniFFI calls are synchronous on the calling thread. Load and verify already run
off the main actor (`BookStore` uses `async` and `BookWriter` runs off-main), so nothing changes.
Records are `Sendable` value types in Swift (`extension Book: Sendable {}`, as generated).

**Errors.** Rust's `#[derive(uniffi::Error)] enum VerifyError` arrives as a Swift `enum
VerifyError: Error` with the same cases. The generated function signature is untyped `throws`, so
a small Swift facade restores `throws(SaveError)`. It also has to decide what
`UniffiInternalError.rustPanic` becomes (§4.2).

**Safety properties.** The never-fail parser gets *stronger*. Rust can state totality in the
signature and also forbid panics with `#![deny(clippy::indexing_slicing, clippy::unwrap_used,
clippy::expect_used, clippy::panic)]` plus `overflow-checks = true`, and cargo-fuzz can hunt for
panics. In Swift, an out-of-range subscript is an invisible trap. Fault-injection tests are
unaffected: persistence stays in Swift.

### C — B plus persistence and autosave in Rust

**In Rust:** B, plus `BookPackage` (open, create, keep-original, edit, save), rotation, snapshots
and the mirror, the stray-file sweep, both locks, `LockRecord`, `ContentDigest`, the
`FileSystem` trait with its fault-injecting double, and the autosave scheduler and its timers.
**In Swift:** `@Observable` `BookStore`/`OpenBook` shells, alerts, wording, the text bridge and
Diagnostics.

**Why it's the wrong seam.** The autosave contract
([`AutosaveDriver.swift`](../../Sources/SceneItCore/Autosave/AutosaveDriver.swift)) says the saver
"starts in the same main-actor turn as the scheduler's `.saveNow`, so everything before its first
`await` (taking the snapshot of the book) sees exactly the edits the save covers". In C, the
*model* is still in Swift but the *scheduler and timers* are in Rust. Every save then has to call
back from a Rust thread into Swift, hop to the main actor, snapshot, and return the book to Rust.
An invariant that's one actor turn today becomes a cross-thread protocol, which is exactly the
kind of race `StoreRaceTests` exists to rule out. The scheduler belongs next to the owner of the
model, so C only makes sense as a step on the way to E.

**Other costs.**
- `KeptOriginal` (`~Copyable`, consumed by `edit`) and `EditingLock` become UniFFI objects. Those
  are `Arc` handles, and Swift can copy them freely, so "consumed once" turns into a runtime
  check (a `Mutex<Option<T>>` taken in Rust). The alternative is to keep the
  keep-original-then-edit flow entirely inside one Rust function. Inside Rust, affine types make
  the token *stronger* than Swift's.
- The store-level tests (`StoreRaceTests`, `MakeEditableAdversarialTests`, `RepairedOnOpenTests`)
  inject faults through the Swift `FileSystem` protocol. In C, the Rust fault double must be
  reachable from Swift: a test-only constructor exported behind a cargo feature, or a Swift
  foreign trait called for every syscall.
- Volume capabilities (`volumeSupportsSwapRenamingKey`) need `getattrlist`, which takes about 40
  lines of `unsafe`. The computer name needs SystemConfiguration through `objc2`/`core-foundation`,
  or Swift passes it in. SHA-256 needs `sha2` (CryptoKit today).
- Logging: Rust code has to log through the Swift `Log` facade (a foreign trait taking a
  `&'static str` and typed metadata), or it loses ADR 0006's "no runtime strings" guarantee. Rust
  can express that guarantee well.

### D — Rust only for new engines (a search pilot)

Write #30 (`SearchIndex` + `KeywordSearch`) in Rust and rewrite nothing.

**What crosses:** search units (`version, sceneID, field, text`) built in Swift from the working
`Book`, either per query (~1–2 ms for a long novel) or incrementally per edited scene, and ranked
hits back. Progressive results use a foreign-trait callback or repeated `next_batch` calls on an
object. **Pros:** the toolchain, CI, signing and symbolication get exercised for real at no
data-loss risk. PLAN §9.2 already anticipated a Rust backend behind the protocol. Admitted text
is Latin-1, so diacritic folding is a 96-entry table and needs no ICU. **Cons:** it tests the
least important argument for Rust (search isn't trust-critical), and it takes on all of
§3's build machinery for a feature Swift handles easily: the target is 100 ms over 700 KB.
Matching must agree with the codec on what a paragraph is (Swift splits on
`Character.isLineBreak`), which is a small drift surface. The File Cabinet scope decodes filed
copies with the Swift parser, which is fine.

### E — Rust owns the open book (the full backend)

A Rust `BookSession` object owns the `Book`, applies edit commands (replace a scene's body runs,
add or recolor a comment, move a scene to the Boneyard), and runs autosave, persistence and
search on its own threads. Swift holds an `@Observable` view model that mirrors the projections
it needs, refreshed through a foreign-trait callback that hops to the main actor.

**Pros:** a single implementation of every rule. Invariants live in Rust's type system, where
`~Copyable` becomes plain move semantics and `Mutex` becomes ownership. It's the architecture a
Rust programmer expects. **Cons:**
- Everything in C.
- Every model feature still to come (comments, structure undo, tags, the Errors tab) gets designed
  across the boundary.
- `UndoManager` integration: structure undo registers closures, and those closures would call
  Rust commands.
- SwiftUI views need a Swift-side mirror. That mirror is either a full copy (drift-free only if
  generated) or fine-grained getters. Fine-grained getters made of FFI calls inside SwiftUI
  `body`s are a performance and isolation trap.
- None of #15's editor exists yet, so the edit-command granularity would be designed blind.

### Others considered and set aside

- **Rust in a separate process (an XPC helper):** isolation nobody asked for, and it costs IPC
  plus another signed bundle.
- **swift-bridge or hand-written C instead of UniFFI:** see §3.
- **A permanent Rust "reference implementation" as a dev-only CLI:** two codecs with no plan to
  delete one is the drift CLAUDE.md forbids. As a *time-boxed* oracle it's B's step 1 (§5).

## 3. Tooling

### Binding generators (late 2026)

| | **UniFFI** (Mozilla) | **swift-bridge** | **Hand C ABI + cbindgen** |
| --- | --- | --- | --- |
| Version | 0.32.2 (pre-1.0; minor versions break things) | 0.1.59 (pre-1.0, one main maintainer) | cbindgen 0.29.4; the C ABI is as stable as you make it |
| Used in production by | Firefox iOS/Android (application-services), Matrix rust-sdk (Element X iOS), others | smaller projects | everyone, by hand |
| Swift 6 strict concurrency | **Verified here:** the generated code compiles under `-swift-version 6` with warnings as errors (Swift 6.4.2). Records are `Sendable`; objects are `@unchecked Sendable` classes, relying on Rust's `Send + Sync` (UniFFI requires it); foreign traits are `AnyObject, Sendable` | not verified in this spike; historically lagged on `Sendable` annotations | whatever you write: a C function imports as `nonisolated`, and you add `Sendable` to your wrappers |
| Errors | Rust `enum` becomes a Swift `enum: Error`; **signatures are untyped `throws`** | `Result` becomes `throws` | out-parameters or status codes; you write the mapping |
| Async | `async fn` becomes Swift `async`, polled without a Rust runtime unless you opt into tokio. **Cancelling the Swift task doesn't cancel the Rust future**, and the generated code `fatalError`s on `CALL_CANCELLED` ("Cancellation not supported yet") | supported (per docs) | callbacks plus continuations, by hand |
| Callbacks (Swift → called from Rust) | `#[uniffi::export(with_foreign)] trait` becomes a Swift protocol (verified) | supported | function pointers plus a context pointer |
| Zero-copy | `&[u8]` arguments ("ByRef bytes", new in 0.32); otherwise everything is serialized into a `RustBuffer` | some | yes: a borrowed `UnsafeRawBufferPointer` costs nothing (measured ~0 for 700 KB) |
| Amount of glue | generated: 1,481 lines of Swift for 10 functions, 3 records, 1 error, 1 object, 1 callback trait | generated in `build.rs` | ~5 lines of C header per function, plus Swift wrappers you write and test |

**Recommendation if you go ahead: UniFFI.** It has the most users, it generated Swift 6-clean code
here, and its error, record and object mapping is what Scene It needs. Hand-written C is the right
call only for one or two hot functions (not needed: 1 µs is fine) or if UniFFI's churn becomes a
problem. swift-bridge's bus factor and unverified Swift 6 story make it the weakest of the three.

### Getting the library into the build

- **Static library, not a dylib.** The Rust code links into the app's main binary. That means no
  extra signature, no extra notarization item, and no hardened-runtime entitlement: Rust doesn't
  JIT. A dylib or framework would need embedding and signing with Developer ID and `--timestamp`.
  The spike's 21 MB `.a` (std, dependencies and line tables) dead-stripped to a 930 KB executable.
- **XCFramework as a SwiftPM `binaryTarget(path:)`** in `Package.swift` (verified). `SceneItCore`
  depends on it, so both `swift test` and the Xcode app pick it up with no change to the pbxproj.
  The catch is that SwiftPM resolves a `binaryTarget` when it *loads the package*, so the
  XCFramework must exist before `swift build` or Xcode opens the project. Choices:
  1. **A script builds it** (`scripts/rust.sh`). `check.sh`, `release.sh` and a scheme
     **pre-action** for Xcode builds call it, and it stays gitignored. Rebuilding after a Rust
     edit took **2.5 s** in the spike (cargo, then bindgen, then `xcodebuild -create-xcframework`).
     The risk is a *stale* library when someone builds in Xcode without the pre-action. UniFFI's
     generated `uniffiEnsureInitialized` `fatalError`s on an API checksum mismatch, which catches
     signature drift but not behaviour drift.
  2. **A SwiftPM build-tool plugin running cargo:** sandboxed (no network, writes only to the
     plugin's work directory), so cargo needs vendored dependencies and `--offline`. It's fragile,
     and Xcode asks the user to trust the plugin.
  3. **Commit the XCFramework:** tens of MB of binary churn in git. No.

  Option 1 is the conventional one.
- **Universal builds.** The Release config builds the standard architectures (arm64 + x86_64), and
  macOS 26 ([ADR 0003](../decisions/0003-minimum-macos-26.md)) still runs on Intel. The steps are
  `rustup target add x86_64-apple-darwin`, `cargo build` for each target, `lipo -create` into one
  `.a`, and then `-create-xcframework` (a `macos-arm64_x86_64` slice). **Not demonstrated:** only
  `aarch64-apple-darwin` is installed here, and per the brief I installed nothing. Debug builds
  use `ONLY_ACTIVE_ARCH = YES`, so they need only arm64.
- **`scripts/check.sh`** gains steps before `swift test`: `cargo fmt --check`,
  `cargo clippy --all-targets -- -D warnings`, `cargo test`, then the XCFramework build. The
  generated Swift must be **excluded** from `swift format lint --strict` (1,216 findings in the
  spike's file) and from `guards.sh`. Its trap messages are static, so `forbid_interpolated_traps`
  wouldn't fire today, but it isn't our code to police. The first cold build took **79 s** for
  the library and **~70 s** for the bindgen tool; both are cached after that.
- **`scripts/release.sh`** builds the universal Rust library before `xcodebuild archive`. Nothing
  changes for signing or notarization when the library is static.
- **dSYMs and crash reports.** Build Rust with at least `debug = "line-tables-only"`. Then
  `dsymutil` on the app pulls the Rust DWARF out of the `.a` members, and the archive's dSYM
  covers Rust frames. **Verified:** `atos` against the spike's dSYM resolves a Rust address to
  `_RNvCskOLv86QPerD_10scene_core5admit (in SpikeTool) (lib.rs:35)`. File and line are right,
  but the name stays **v0-mangled**: Apple's tools don't demangle Rust. `.ips` files and MetricKit
  call-stack trees (ADR 0006) are offsets plus binary UUIDs, so they symbolicate the same way.
  Readable names need `rustfilt` in the triage step, or `-C symbol-mangling-version=legacy`,
  which looks like C++ but carries hashes.
- **Debugging.** `lldb` (in Xcode or the CLI) sets breakpoints on Rust symbols and file:line, and
  shows Rust source and inlined frames. **Verified:** `breakpoint set -r scene_core5admit` stopped
  in `admit at lib.rs:36:33` from a Swift caller. It warns that it "has no plugin for the
  language rust", so variable inspection is C-like at best, and absent with line-tables-only. A
  full `debug = true` dev profile helps. Many people attach RustRover or VS Code with CodeLLDB to
  the running app for the Rust side.

## 4. Trust

### 4.1 What Rust buys

- **Reviewability by the owner.** It's the strongest argument. Trust-labelled code
  (`trust` issues: the parser, save and verify, backups, locks) is the code you most need to read
  closely, and Rust is the language you read best.
- **Real fuzzing.** cargo-fuzz (libFuzzer) works on macOS with nightly; nightly is installed here
  and `cargo-fuzz` isn't. **Swift has no equivalent on this toolchain:** `swiftc
  -sanitize=fuzzer` reports `unsupported option '-sanitize=fuzzer' for target
  'arm64-apple-macosx27.0.0'` (checked). Today's `FuzzTests.swift` is seeded random generation
  with no coverage feedback.
- **Property tests:** `proptest` is mature. The spike's two properties ("admit is idempotent" and
  "every byte string parses and verifies") ran in milliseconds.
- **No-panic as a lint-enforced policy.** Clippy lints can *forbid* the constructs that can panic
  (indexing, `unwrap`, arithmetic). Swift has no lint for a trapping subscript.
- **Ownership.** `~Copyable` + `consuming` (`KeptOriginal`), `deinit`-released locks and `Mutex`
  regions are Rust's native vocabulary, and stricter there: affine by default, `Drop`, `Send`/`Sync`
  inferred. ARC retain cycles disappear inside Rust, though Scene It has only one known
  weak-reference site (`AutosaveDriver.saver`) and it's deliberate.
- **Miri** for any `unsafe` (the persistence FFI in C/E).

### 4.2 What it costs

- **The boundary is new bug surface.**
  - Buffer and string lifetimes: UniFFI handles them, while hand C has to get `ScBuffer` freeing
    right. Spike lesson: the `ByRef` zero-copy path is valid only inside `withUnsafeBytes`.
  - `Arc` handles that Swift can copy.
  - Untyped `throws`.
  - No cancellation of async calls.
- **Panics across FFI.**
  - UniFFI catches unwinding panics. In a *throwing* function the panic becomes
    `UniffiInternalError.rustPanic("<message>")` (verified). In a *non-throwing* one the
    generated `try!` traps, and **Swift's trap message includes the panic message**. That
    violates the reason `forbid_interpolated_traps` exists: crash reports, which are sent to the
    owner, include trap messages verbatim.
  - Rust 1.98's string-slicing panic no longer quotes the string (checked), but
    `expect("…{x}")`, `panic!("{…}")` and `unwrap()` on an error with `Debug` output still can.
  - Choices: `panic = "abort"`, which gives a clean `SIGABRT` `.ips` with Rust frames and keeps
    the message out of the report (Rust prints it to stderr), plus the clippy denials above, plus
    a panic hook that records only a static location in `LogRing`.
  - With "never fail" and "never lose text" as the rules, **abort** is the honest policy: a
    panicking parser isn't safe to keep calling.
- **Two toolchains** to keep current. `rustup` and Xcode move independently, and so do UniFFI
  minor versions and Swift language modes.
- **About 30 third-party crates** in the library's resolved graph (about 55 counting proc-macros,
  about 90 for the bindgen tool): `uniffi*`, `unicode-normalization`, `thiserror`, `anyhow`,
  `serde`, … That's a direct reversal of README rule 3 and PLAN §2, and it needs `cargo audit`/
  `cargo deny` in the gate.
- **Tutorials.** Chapters 02, 03, 03a and 04 are anchored in the Swift code. B rewrites 02. C and
  E rewrite 02–04 and add a chapter on FFI. That chapter would be a good one for you to read, but
  it costs time.
- **Reviews start over.** The existing code has been through adversarial review (`trust` label).
  A rewrite has to be reviewed again with the same care, and in practice that's the binding cost:
  agents wrote `SceneItCore` in two days, so the typing is cheap.

### 4.3 The drift hazard, concretely

CLAUDE.md: "A forked or parallel implementation of anything *will* diverge." In B and every
option after it, these must exist **only in Rust**, and Swift must call them:

- **`admit`/`admitted`/`admittedLine`.** The editor will call them on every keystroke and paste
  (#15/ADR 0022), the parser on every file. At ~1 µs a call, FFI on every keystroke is fine.
- **NFC.** Today it's Foundation's `precomposedStringWithCanonicalMapping`. In Rust it would be
  `unicode-normalization`'s tables. If *anything* in Swift still normalizes (a paste handler, say),
  the Unicode versions of the two table sets can disagree. Mitigation: only Rust normalizes, and
  the fast path stays ("all bytes < 0xCC means already NFC").
- **Line breaks.** `RunCodec` splits paragraphs on Swift's `Character.isLineBreak`, and
  `admitted(_:)` maps the same set to `\n`. The Rust parser needs the identical set, so define it
  as an explicit table in Rust and have `RunCodec` ask Rust, or pass the whole string to Rust to
  split. (Seven uses of `isLineBreak` in `Sources/` today.)
- **Word boundaries** (ADR 0023): `Character.isWhitespace` and Rust's `char::is_whitespace` both
  follow Unicode White_Space, but on different units: graphemes versus scalars. For Latin-1
  admitted text they agree, *if* only admitted text is ever counted.

During a shadow phase (§5) there will be two codecs **on purpose**. That's acceptable only with a
date fixed in advance by which one is deleted.

## 5. Migration cost and an incremental path

### Rewrite size

| Option | Swift code moved | Swift tests moved | New Rust | New Swift glue |
| --- | ---: | ---: | --- | --- |
| A | 0 | 0 | 0 | 0 |
| B | ~3,200 (Format 2,081, policy/model ~1,040, WordCount 90) | ~2,800 | about the same, plus fuzz targets | ~300–600 (facade, custom types, error mapping) + build scripts |
| C | ~6,600 (B + Persistence ~2,870, scheduler/quit 339, BookWriter 141) | ~8,000 | + `FileSystem` trait, fault double, `unsafe` volume FFI | + callback bridge into `@Observable` stores |
| D | 0 | 0 | ~1,500–2,500 (search) | ~200 |
| E | ~7,500 + all future model logic | ~9,000 | + command API | + view-model mirror |

**Reusable as is:** the format spec ([`book-format.md`](../format/book-format.md), 991 lines and
language-neutral), the three fixtures (`complete-example.md`, `damaged-example.md`,
`demo-book.md`), the spec's §9 examples, and the generators in `FuzzTests.swift`, whose structural
pieces and mutation kinds port to a cargo-fuzz dictionary and mutator.

### An incremental path for B (shippable at every step)

0. **Decide (ADR) and do the work that pays off anyway.** Turn the spec examples and fixtures
   into a language-neutral corpus: `input.md`, `canonical.md` and an `errors.txt` listing the
   error entries. Point the Swift tests at it, with no change in behaviour. This step is useful
   **even under A**.
1. **Write the Rust codec from the spec, test-only.** A `rust/` workspace that passes the corpus,
   with proptest and cargo-fuzz. `check.sh` runs `cargo fmt`, `clippy` and `test`. The app is
   untouched.
2. **Differential testing.** Build the XCFramework, then add a Swift test that runs *both* codecs
   on the corpus, on Swift's seeded generators and on the cargo-fuzz corpus. Every difference is a
   bug in one of them or an ambiguity in the spec, and fixing those is worth something whether or
   not Rust ships. **Decision point:** promote or delete, on the date fixed in step 0.
3. **Switch.** `BookFormat`'s Swift API delegates to Rust. The model becomes generated records
   with custom types for admitted text, and `CharacterPolicy` calls Rust. The Swift codec stays
   for one cycle as a test-only oracle.
4. **Delete the Swift codec.** Rewrite tutorial 02 around the Rust code.

C or E would continue the same way: persistence behind the existing `FileSystem`-shaped API, then
the store. Doing that before #15 means designing the edit boundary with no editor to try it on.

## 6. The spike

In `/private/tmp/claude-501/rust-spike/` (throwaway, not in the repo). Toolchain: rustc/cargo
1.98.0, Swift 6.4.2, Xcode 27.2, macOS 27 on arm64.

**What it is:**
- A `scene-core` crate (`crate-type = ["staticlib", "lib"]`, UniFFI 0.32.2 proc-macros) with:
  - `admit` (a port of `CharacterPolicy.admit`)
  - a toy never-fail `parse_book`, `serialize_book` and `verified_serialization -> Result<_, VerifyError>`
  - an `async fn`
  - a `Session` object with a `Mutex<Book>`
  - a Swift-implemented `Sink` foreign trait
  - a deliberate panic
  - two hand-written `extern "C"` functions for comparison
  - proptest properties
- A separate `uniffi-bindgen` crate.
- `build.sh`: cargo, then bindgen, then `xcodebuild -create-xcframework`.
- `SpikePkg`: `binaryTarget` + generated Swift target + Swift Testing tests, in
  `swiftLanguageModes: [.v6]` with `.treatAllWarnings(as: .error)`.

**Results:** all five Swift tests pass in debug and release. `cargo test` passes (one unit test
and two proptests), and so does `cargo clippy -D warnings`.

| Measurement (release Swift, release Rust) | Result |
| --- | ---: |
| Send 700 KB `Data` to Rust (UniFFI copy) | 1.4 ms |
| Same, through C ABI with a borrowed pointer | ~0 |
| Parse in Rust and bring back a 60-scene/1,200-paragraph tree | 12.6 ms (11.0 ms of it is the toy parser's NFC on every line; ~1.5 ms is the lift) |
| Send a tree to Rust and serialize | 0.65 ms |
| `admit("e")` per call, UniFFI / C ABI | 1.1 µs / 0.03 µs (debug Swift: 2.0 µs / 0.15 µs) |
| `admit` on a 1,000-character paragraph, UniFFI | 3.2 µs |
| *For reference:* the Swift codec on a 120k-word book | parse 27 ms, serialize 12 ms, verified save 50 ms |
| Cold build: library / bindgen tool | 79 s / ~70 s |
| Edit → rebuilt XCFramework | 2.5 s |
| Static lib on disk → linked executable | 21 MB → 930 KB |

**Friction I actually hit, in order:**
1. With the `cli` feature on the library crate, the bindgen pulled `askama`, `cargo_metadata` and
   friends into the static library (104 MB). Fix: put bindgen in its own crate (21 MB).
2. Clippy 1.98 wanted a let-chain (edition 2024) in my code. That's routine.
3. The generated modulemap is named `scene_coreFFI.modulemap`. An XCFramework's `Headers/` needs
   `module.modulemap`, so I wrote one by hand.
4. The Swift 6 compiler rejected my *test's* needless `await`. The generated bindings compiled
   cleanly.
5. Untyped `throws`, `try!` on non-throwing calls, and no async cancellation, as covered in §3
   and §4.2.
6. lldb: Rust source is visible, but there's no Rust language plugin. `atos`: Rust names stay
   mangled.
7. No x86_64 target installed, so universal builds weren't demonstrated. Not installed, per the
   brief.
8. `cargo-fuzz` isn't installed, so fuzzing wasn't demonstrated. Proptest worked.

## 7. Recommendation and decisions

### Recommendation

**Stay with A now. Do step 0 (the shared corpus) regardless.** If you want to find out what Rust
would feel like here, run **B's steps 1–2 as a time-boxed experiment** with a promote-or-delete
date. **Avoid C**, and **revisit E only after M2** shows what the editor's edit traffic looks like.

**Confidence: moderate (about 65%) that A, or A plus a shadow experiment, is right for this
project; high (about 85%) that C is the wrong boundary.** What would change my mind:
- If personal reviewability of the trust code matters more to you than the costs in §4.2,
  B-with-promotion becomes the better choice. It's the one option where Rust's strengths land on
  the code that most needs them, and it touches no AppKit.
- If a non-Apple target ever comes into scope (PLAN §1 excludes it for v1), E becomes worth its
  price.

Why not more confident either way? Because the deciding factor is *your* fluency and appetite,
and only you can weigh that. Technically, both A and B are sound. The spike found no blocker,
only friction with known workarounds.

### Decisions for you

Each comes with what deciding it would teach a Rust programmer.

1. **What's the goal: reviewability, assurance, learning, or portability?** Reviewability points
   to B (the parser). Assurance points to B plus cargo-fuzz. Learning the boundary cheaply points
   to D. Portability points to E, and PLAN §1 excludes it for v1. *Learning:* each answer leads to
   a different boundary, and the boundary is the architecture.
2. **Third-party dependencies.** Approve UniFFI (plus about 30 crates) and `unicode-normalization`,
   and for C/E `libc`/`rustix` and `sha2`? This overrides README rule 3 and PLAN §2, so it needs
   an ADR. *Learning:* reading `cargo tree` with the same suspicion as a Swift dependency.
3. **The binding layer:** UniFFI (generated, untyped `throws`, `Arc` objects) or hand-written C
   (total control, every lifetime by hand)? *Learning:* UniFFI's `RustBuffer` and handle maps
   are a compact course in FFI ownership. Reading the 1,481 generated lines is worth an hour.
4. **Where the model lives** (B): generated records with custom types for admitted text,
   enforced at the boundary, or opaque handles (E)? *Learning:* the trade between invariants
   held in a type system and invariants enforced on entry.
5. **Panic policy:** `panic = "abort"` plus clippy denials (recommended), or unwind plus
   `rustPanic` errors? *Learning:* how `catch_unwind`, `extern "C-unwind"` and Swift traps meet,
   and what ends up in a crash report.
6. **Build integration:** a script plus a scheme pre-action (recommended) or a SwiftPM plugin?
   Add x86_64 (needed for Release while macOS 26 runs on Intel)? *Learning:* how SwiftPM resolves
   `binaryTarget`s and what an XCFramework contains.
7. **Time box:** if you run the shadow experiment, what date and what criteria decide whether it's
   promoted or deleted? For example: zero differential mismatches over N fuzz hours, and a review
   cost you're happy with.

### What to pause while you decide

- **Continue:** #15 (the TextKit 2 editor), #16, #18–#22, #24–#25, #28, #31, #33, #35, #37, #39,
  and the in-progress #63/#67. They're Apple-side under *every* option. #15's only core touchpoint
  is the debounced `RunCodec` → `Paragraph` path. `RunCodec` stays Swift (it's AppKit), and
  `Paragraph` keeps its shape under B: a generated record with the same fields.
- **Pause, or don't start:**
  - **#30 search engine:** the language is the open question (D).
  - **#32 archive reconciliation:** persistence logic that C/E would move.
  - **The model side of #23** (comment operations): model rules that E would move.
  - **Refactors of `Format/` or `Persistence/` internals beyond bug fixes**, so the rewrite target
    doesn't move.
- **Start now regardless:** step 0, the language-neutral corpus.
