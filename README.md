# Scene It

A macOS app for writing a novel as an ordered list of scenes, built in Swift 6 with
SwiftUI and AppKit (TextKit 2). The whole book lives in one `.sceneit` package.
Data safety comes first: verified atomic saves, rotating and tiered backups, an
external mirror, and immutable filed copies.

| Where | What |
| --- | --- |
| [`novel-app-build-bundle/PLAN.md`](novel-app-build-bundle/PLAN.md) | Product spec |
| [`docs/decisions/`](docs/decisions/) | Decisions and deviations from the spec (these win over PLAN) |
| [`docs/dev/WORKFLOW.md`](docs/dev/WORKFLOW.md) | How work is picked up, built, reviewed and merged |
| [`docs/tutorial/`](docs/tutorial/) | Walkthrough of the app for Rust programmers new to Swift and macOS |
| [GitHub issues](https://github.com/samitbasu/scene-it/issues) | Work queue, milestones M0–M7 |

## Requirements

- macOS 26 or later (ADR 0003)
- Xcode 27 (`xcode-select -p` should point at `/Applications/Xcode.app/Contents/Developer`)
- For releases only (`scripts/release.sh`): membership of team `8H6754RJ2W` in the Apple
  Developer Program, the *Developer ID Application* certificate with its private key in the
  login keychain (`security find-identity -v -p codesigning` lists it), and, except for
  `--unnotarized`, a `notarytool` keychain profile named `scene-it-notary` (see release.sh
  below). Debug builds, `scripts/check.sh` and the tests need none of these: Debug is signed
  ad hoc.

## Repository layout

```
Package.swift              SwiftPM package: SceneItCore (model, persistence, backups,
Sources/SceneItCore/         archive, search, problem reports) and its tests
Tests/SceneItCoreTests/
SceneIt.xcodeproj          app target, which uses synchronized folders
SceneIt/                   app sources (SwiftUI + AppKit UI)
SceneItTests/              app-hosted tests (run through xcodebuild)
Config/                    Info.plist and other build configuration
.swift-format              formatter and lint rules (used by both scripts)
scripts/                   the scripts below; lib.sh holds shared paths and log helpers, guards.sh the source guards
Justfile                   optional shortcuts for the scripts (see Scripts)
docs/                      decisions, workflow, tutorials
build/                     all build output (git-ignored)
dist/                      release artifacts (git-ignored)
```

## Scripts

All scripts are run from the repository root, use `bash` with `set -euo pipefail`,
and exit non-zero on failure. **Status** shows whether a script exists yet. A
script marked *planned* lands with the issue named, and its section is updated
from the real behaviour when it merges.

### `Justfile`: optional shortcuts

[`just`](https://github.com/casey/just) runs the recipes in the top-level `Justfile`. Each
one is a one-line wrapper around a script below or a standard command, so `just` is never
required: the table gives the plain equivalent of every recipe.

```sh
cargo install just      # or: brew install just
just                    # same as just --list: every recipe, with its description
just test-filter Corpus # extra arguments are passed through where the table shows ARGS
```

| Recipe | Runs |
| --- | --- |
| `just check` | `scripts/check.sh` |
| `just fmt` | `scripts/format.sh` |
| `just lint` | the gate's lint step alone: `lint_swift` from `scripts/lib.sh` (`swift format lint --strict` over the Swift paths) |
| `just guards` | `scripts/test-guards.sh`, then every source guard (`forbid_all` in `scripts/guards.sh`) over the Swift paths |
| `just test ARGS` | `swift test ARGS` (SceneItCore) |
| `just test-app ARGS` | `xcodebuild … -derivedDataPath build/DerivedData test ARGS` (the app-hosted tests, as the gate runs them) |
| `just test-filter PATTERN ARGS` | `swift test --filter PATTERN ARGS` |
| `just coverage ARGS` | `scripts/coverage.sh ARGS` |
| `just fuzz-page SEEDS=8 STEPS=1500` | the longer page fuzz (below), e.g. `just fuzz-page 16 3000` |
| `just corpus-regenerate` | `CORPUS_REGENERATE=1 swift test --filter CorpusConformance` (`Tests/Corpus/README.md`), then a reminder to review the diff |
| `just build ARGS` | `xcodebuild … -derivedDataPath build/DerivedData build ARGS` (Debug) |
| `just run` | `just build`, then `open "build/DerivedData/Build/Products/Debug/Scene It.app"`. It uses your own preferences and books, like running from Xcode. |
| `just open` | `open SceneIt.xcodeproj` |
| `just release` | `scripts/release.sh` |
| `just release-unnotarized` | `scripts/release.sh --unnotarized` |
| `just clean` | deletes `.build/` and everything in `build/` except `build/release/`, which holds the dSYMs of shipped builds |

### `scripts/check.sh`: the commit gate

**Status:** available.

```sh
scripts/check.sh
```

Takes no arguments. The Swift paths it checks are `Package.swift`, `Sources/`,
`Tests/`, `SceneIt/` and `SceneItTests/`. They're defined once in `scripts/lib.sh`,
which check.sh and format.sh source. It first deletes `build/check/SceneIt.xcresult`, then
runs, in order, stopping at the first failure:

1. `scripts/test-guards.sh` (below): checks that the source guards in steps 2–4 reject
   and accept what they should.
2. **TextKit 1 guard:** fails if any `.swift` file in those paths matches
   `\blayoutManager\b|NSLayoutManager|usingTextLayoutManager: *false`.
   `textLayoutManager` is allowed.
3. **Logging guard:** fails on `Logger(`, `os_log`, `OSLog…` or `NSLog(` outside
   `Sources/SceneItCore/Diagnostics/Log.swift` and `CurrentProcessLog.swift`. All logging
   goes through `Log`, whose types keep manuscript text out (ADR 0006).
4. **Trap-message guard:** fails on string interpolation (`\(`) on the same line as
   `fatalError(`, `precondition(`, `preconditionFailure(`, `assert(` or `assertionFailure(`.
   Crash reports, which problem reports include verbatim, quote these messages.

   Steps 2–4 are functions in `scripts/guards.sh`, listed once in its `source_guards`. Each one fails if a path is missing,
   ignores lines that are only a `//` comment, and prints `file:line: error: <rule>: <line>`
   for each hit.
5. `swift format lint --strict --recursive` over those paths, using `.swift-format`.
6. `swift test` (SceneItCore unit tests; build output in `.build/`).
7. `xcodebuild -project SceneIt.xcodeproj -scheme SceneIt -destination 'platform=macOS'
   -derivedDataPath build/DerivedData -resultBundlePath build/check/SceneIt.xcresult test`.
   This builds the app and runs the app-hosted tests. Compiler warnings are errors,
   through the project's build settings and the package manifest. Linker warnings
   are not fatal.

Each step has a wall-clock limit: 5 minutes for steps 1–5, 15 for `swift test`, 45 for
xcodebuild. A step still running at its limit fails. Swift Testing's own time limits can't
end a test that's blocked, so without this a hung test hangs the gate (#77). At the limit,
check.sh kills two sets of processes: the step's own process tree, and any process that runs
something from `.build/` or `build/`, started while the step ran, and isn't `Scene It.app`.
That spares a Debug app or an IDE build that was already running, and an app the step didn't
start itself. Before it kills them, check.sh samples up to four of them that are test runners
(`swiftpm-testing-helper`, an `.xctest` bundle or a test host app), all at once, for 3 seconds,
into `build/check/<step>-hang-<pid>.txt`.

**Output on success:** nothing, exit status 0.

**Output on failure:** exit status 1, and on stderr:
`check.sh: <step> failed (full log: build/check/<step>.log)`, followed by the
`error:`/`warning:`/`✘` lines from that log, or its last 50 lines if none match.
A step that ran out of time adds `error: still running after <n> min (or s), so it was killed: <command>`
and the path of the samples. Only when the xcodebuild step fails, each failing test from
that run's result bundle is also listed as `✘ <target>/<test>: <failure text>`.

**Products:** one log per step in `build/check/` (`guard-tests.log`, `textkit1-guard.log`,
`logging-guard.log`, `trap-message-guard.log`, `lint.log`, `swift-test.log`, `xcodebuild.log`), the test result bundle
`build/check/SceneIt.xcresult` (open it in Xcode), and the built app at
`build/DerivedData/Build/Products/Debug/Scene It.app`. All of `build/` except
`build/release/` (see release.sh) can be deleted at any time. Run this before every commit; nothing lands on `main`
without it passing.

### `scripts/test-guards.sh`: tests for the source guards

**Status:** available.

```sh
scripts/test-guards.sh
```

Takes no arguments; `check.sh` runs it first. For each guard in `scripts/guards.sh`, it
writes one-line Swift fixtures into a temporary directory. The guard must reject each
violating fixture, reporting the fixture's `file:1`, and accept each allowed one: exempt
files, comments, interpolation outside traps. It also checks that a missing path fails
with status 2. **Output:** nothing on success. On failure, one `✘` line per case that went
the wrong way, and exit status 1. **Products:** none; the fixtures are deleted on exit.

The gate never rewrites the format test corpus: `check.sh` unsets `CORPUS_REGENERATE` (see `Tests/Corpus/README.md` for regenerating cases on purpose).

### `scripts/format.sh`: apply formatting

**Status:** available.

```sh
scripts/format.sh
```

Takes no arguments. Runs `swift format format --in-place --recursive` over
the Swift paths from `scripts/lib.sh`, using `.swift-format`. These are the same
paths and rules `check.sh` lints against. Some lint
findings (naming, for example) can't be fixed automatically and still need a
manual edit. **Output:** modified source files only; review them
with `git diff`.

### `scripts/coverage.sh`: line coverage

**Status:** available. Not part of the gate.

```sh
scripts/coverage.sh               # SceneItCore and the app (about 4.5 minutes)
scripts/coverage.sh --core-only   # SceneItCore only (about 1.5 minutes)
scripts/coverage.sh --open        # then open the SceneItCore HTML report
```

1. `swift test --enable-code-coverage`, skipping `ScalingTests`, `PerformanceTests` and
   `SearchPerformanceTests`: they compare timings, which instrumentation distorts. Then `xcrun llvm-cov` over the
   SceneItCore test binary (found through `swift build --show-bin-path`) and the profile
   `swift test --show-codecov-path` names, leaving out `Tests/` and `.build/`: a summary and
   an HTML report.
2. Unless `--core-only`: `xcodebuild … -enableCodeCoverage YES test` with its own
   DerivedData (`build/coverage/DerivedData`, so the gate's incremental build is left alone),
   then `xcrun xccov view --report --json` for the `Scene It.app` target.

**Output:** line coverage per area (each directory under `Sources/SceneItCore/` and
`SceneIt/`; a row named for the folder itself counts the files directly in it), each module's total, the five least-covered files, the skipped suites and the
report paths. For example:

```
Area                                  Covered    Lines   Cover
SceneIt                                    74      186   39.8%
…
Sources/SceneItCore/Autosave              378      384   98.4%
…
Sources/SceneItCore/Window                172      241   71.4%

Total SceneIt                            2065     2430   85.0%
Total Sources/SceneItCore                7033     7456   94.3%

Least covered files:
  0.0%      0/25     Sources/SceneItCore/Diagnostics/DiagnosticsDirectory.swift
…

Skipped under coverage (timing-sensitive): ScalingTests PerformanceTests
Core HTML: /Users/samitbasu/Devel/scene-it/build/coverage/core-html/index.html
App result bundle: /Users/samitbasu/Devel/scene-it/build/coverage/app.xcresult
```

**Output on failure:** exit status 1 and `coverage.sh: <step> failed (full log:
build/coverage/<step>.log)` followed by that log's error lines, as for check.sh. A failing
test fails the run. Unknown arguments print the usage and exit 2.

**Products:** in `build/coverage/`: `core-html/index.html`, `app.xcresult` (open it in Xcode
for the app's per-line coverage), `files.tsv` (path, covered lines, executable lines, per
file), one log per step, and the app build in `DerivedData/`.

### A longer run of the page fuzz

Not a script: `SceneItTests/AdversarialPageTests.swift`'s `PageFuzzTests` makes random edits to
the real page through every path that changes its text, checking the model and the page after
each. The gate runs 2 seeds × 200 steps. For a longer run, give the seed count and the steps
per seed:

```sh
TEST_RUNNER_PAGE_FUZZ_SEEDS=8 TEST_RUNNER_PAGE_FUZZ_STEPS=1500 xcodebuild -project SceneIt.xcodeproj \
    -scheme SceneIt -destination 'platform=macOS' -derivedDataPath build/DerivedData \
    test -only-testing:SceneItTests/PageFuzzTests
```

`NotesFuzzTests` (in `SceneItTests/NotesFuzzTests.swift`) does the same for the page and the
notes together, across scene and tab switches; the gate runs 2 seeds × 120 steps, and
`TEST_RUNNER_NOTES_FUZZ_SEEDS` and `TEST_RUNNER_NOTES_FUZZ_STEPS` run more, with
`-only-testing:SceneItTests/NotesFuzzTests`.

Seeds run 1 to N, so a failure is replayed with the same N. Each seed's time limit grows with
the steps (never under two minutes). **Output:** the test results; a failure lists the last
steps before the page and the model disagreed. **Products:** none beyond the result bundle.

### A longer run of the formatting fuzz

Not a script: `SceneItTests/FormattingFuzzTests.swift` applies random formatting commands to
random selections of the real page, each as its own event. After each command it checks the
controls' states against an oracle, checks that the text and comments are untouched and that
the page and model agree, and checks the caret's typing format and undo/redo. The gate runs
2 seeds × 40 steps. For a longer run:

```sh
TEST_RUNNER_FORMAT_FUZZ_SEEDS=8 TEST_RUNNER_FORMAT_FUZZ_STEPS=300 xcodebuild -project SceneIt.xcodeproj \
    -scheme SceneIt -destination 'platform=macOS' -derivedDataPath build/DerivedData \
    test -only-testing:SceneItTests/FormattingFuzzTests
```

Seeds run 1 to N. **Output:** the test results, each failure naming its step. **Products:** none
beyond the result bundle.

### Rendering the window for review

Not a script: a hosted test, `SceneItTests/WindowRenders.swift`, that draws the main window
offscreen into PNGs (no screen capture), for aesthetic reviews (CLAUDE.md: show the owner
rendered candidates). It's skipped unless an output folder is given:

```sh
TEST_RUNNER_SCENEIT_RENDER_DIR=/tmp/window-renders xcodebuild -project SceneIt.xcodeproj \
    -scheme SceneIt -destination 'platform=macOS' -derivedDataPath build/DerivedData \
    test -only-testing:SceneItTests/WindowRenders
```

**Output:** for each window state (`final-window`, `final-scenes-sheet`, `final-panel-collapsed`,
`final-boneyard-scene`, `final-no-scene`, `final-start`), `<name>@1x.png` and `<name>@2x.png`
at 1440 × 900 pt, and `<name>-vs-mockup.png` beside `01-main-window.png`. Its books and
preferences are throwaway (a temporary folder, a test-host `BookController`). To compare
candidates for a future look change, render each candidate the same way with a different name.

It also renders a damaged book (`final-banner-repaired`, `final-errors-tab-read-only`,
`final-errors-tab`, and `final-errors-focus`, the tab with the keyboard focus) and a book saved by a newer version (`final-banner-newer`), the same way.

The Search sheet's renders (`SearchSheetRenders.swift`, #31) go in a `search/` subfolder: each
state (`search-prompt`, `search-exact`, `search-exact-expanded`, `search-near`,
`search-near-end`, `search-near-all`, `search-no-results`, `search-no-words`,
`search-this-scene`, `search-long`) at 1× and 2× and beside `10-search-whole-book.png`. To
render only these, add `-only-testing:SceneItTests/WindowRenders/searchSheet\(\)`.

### `scripts/release.sh`: build a distributable app

**Status:** available. The default mode also needs the `scene-it-notary` profile
(see *Setting up notarization* below).

```sh
scripts/release.sh                 # signed, notarized, stapled DMG
scripts/release.sh --unnotarized   # signed but not notarized zip, for testers only
```

**It refuses to run** (exit status 1, reason on stderr), before building anything, if:
- the working tree has uncommitted or untracked changes, because the build number must
  name a commit;
- `HEAD` is not on `origin/main` (checked after `git fetch origin`), or the clone is shallow.
  Only merged commits are released, so each build number names one commit and later
  releases get higher numbers;
- the *Developer ID Application: Samit BASU (8H6754RJ2W)* identity isn't in the keychain;
- in the default mode, `notarytool` can't use the `scene-it-notary` profile. The message
  prints the command that creates it;
- `build/release/<version>-<build>[-unnotarized]/` already exists, because it may hold the
  dSYM of a build that was shipped. Delete it only if nothing from it was shipped. (A
  leftover `….partial/` directory from an interrupted run is deleted and rebuilt instead.);
- `~/Library/Developer/Xcode/Archives/<today>/Scene It <version>-<build>[-unnotarized].xcarchive`
  already exists;
- the artifact in `dist/` already exists. Bump `MARKETING_VERSION` or delete the file;
- `scripts/check.sh` fails. Its diagnostics are printed. There is no flag to skip it.
  check.sh's time limits apply here too, so a hung test stops the release instead of
  hanging it.

Each of the steps below that runs a command and logs to `logs/` (archive, export, signing
checks, zip, DMG) fails if it runs for more than an hour, in the same way as a check.sh step.
The notarization waits and the stapling retries aren't limited.

The version is the project's `MARKETING_VERSION`. The build number is
`git rev-list --count HEAD`, passed to `xcodebuild` as `CURRENT_PROJECT_VERSION`, so it
becomes the app's `CFBundleVersion` and appears in problem reports.

**Default mode** (all of it inside `build/release/<version>-<build>.partial/`):
1. `xcodebuild clean archive`: Release, universal (arm64 and x86_64), DerivedData in
   `build/release/DerivedData`. Release signs with Developer ID, the hardened runtime and a
   secure timestamp (`--timestamp`).
2. `xcodebuild -exportArchive` with [`Config/ExportOptions.plist`](Config/ExportOptions.plist)
   (method `developer-id`, manual signing, team `8H6754RJ2W`).
3. `codesign --verify --deep --strict`, plus checks that the team, the hardened runtime and
   the timestamp are in the signature.
4. `ditto` zips the app for `xcrun notarytool submit --keychain-profile scene-it-notary --wait`.
   If Apple doesn't accept it, the script prints Apple's log (`notarytool log`) and stops.
5. `xcrun stapler staple` on the app (up to three tries, 15 s and 30 s apart, because the
   ticket can lag behind *Accepted*); `spctl -a -vvv -t exec` must report
   *Notarized Developer ID*.
6. `diskutil image create from --format UDZO` builds the DMG (the app plus an `Applications`
   link), which is signed with Developer ID, notarized and stapled the same way;
   `spctl -a -vvv -t install` must report *Notarized Developer ID*.
7. Copies the `.xcarchive` to `~/Library/Developer/Xcode/Archives/<yyyy-MM-dd>/`, moves the
   DMG into `dist/`, and renames the `.partial` directory to `build/release/<version>-<build>/`.
   Nothing reaches `dist/` unless every check passed.

**`--unnotarized`:** steps 1–3, then a zip of a folder holding the app and a `README.txt`,
then step 7 (the directories end in `-unnotarized`).
The README walks the tester through **System Settings → Privacy & Security → Open Anyway**,
which macOS 15 and later require for an app that isn't notarized (Control-click → Open no
longer bypasses Gatekeeper). The app is still signed with Developer ID, but Gatekeeper
reports it as *Unnotarized Developer ID* and blocks it once. A stopgap only.

**Output on success:** three absolute paths on stdout: the artifact, the dSYM in
`build/release/`, and the archive copy. For example:

```
/Users/samitbasu/Devel/scene-it/dist/Scene It 0.1.0-unnotarized.zip
/Users/samitbasu/Devel/scene-it/build/release/0.1.0-26-unnotarized/Scene It.xcarchive/dSYMs/Scene It.app.dSYM
/Users/samitbasu/Library/Developer/Xcode/Archives/2026-11-01/Scene It 0.1.0-26-unnotarized.xcarchive
```

**Output on failure:** exit status 1 and, on stderr, `release.sh: <step> failed (full log:
build/release/<version>-<build>.partial/logs/<step>.log)` followed by that log's error lines,
or the reason it refused to run.

**Products:**
- `dist/Scene It <version>.dmg` (default) or `dist/Scene It <version>-unnotarized.zip`.
- `build/release/<version>-<build>/` (`…-unnotarized/` for `--unnotarized`): the
  `Scene It.xcarchive`, the exported (and stapled) app in `export/`, the zip sent for
  notarization, and one log per step in `logs/`. Keep it for every build you ship.
- `~/Library/Developer/Xcode/Archives/<yyyy-MM-dd>/Scene It <version>-<build>[-unnotarized].xcarchive`:
  a copy of the archive outside the repository. Xcode's Organizer lists it, and Spotlight
  indexes its dSYM by UUID, so Console and `mdfind` find it. **Back it up.** Rebuilding a
  commit later produces a binary with different UUIDs (they depend on the build path and
  toolchain), so a lost dSYM can't be recovered, and without it that build's crash reports
  can't be symbolicated ([tutorial 10](docs/tutorial/10-shipping.md#dsyms-and-symbolication)).

**Setting up notarization (once per Mac):** create an app-specific password at
[account.apple.com](https://account.apple.com) → Sign-In and Security → App-Specific
Passwords, then run the command below. It prompts for the password and stores it in the
login keychain, never in the repository.

```sh
xcrun notarytool store-credentials scene-it-notary --apple-id <your Apple ID email> --team-id 8H6754RJ2W
```

## Reading a problem report

Writers send reports from **Help → Report a Problem…** to the address in
`ProblemReport.destination` ([ADR 0009](docs/decisions/0009-report-destination.md)). The
attachment is `Scene It Report <yyyy-MM-dd HHmm>.zip`:

| File | What it tells you |
| --- | --- |
| `manifest.txt` | Every file in the zip and why, plus anything that couldn't be gathered. Read it first. |
| `system.txt` | App version and build, macOS version, Mac model, and settings and backup status |
| `logs/recent-sessions.log` | Our own log across launches (UTC). `Launched lastSession=crashed` starts the session after a crash. |
| `logs/this-session.log` | The same messages for the sending session, read from the unified log |
| `crash-reports/*.ips` | macOS crash reports. Open them in Console, or read `exception`, `asi` and `faultingThread`. |
| `metrickit/*.json` | Crash and hang diagnostics MetricKit delivered to the app |

Release builds need their dSYM to symbolicate (`atos`). `scripts/release.sh` keeps it in
`~/Library/Developer/Xcode/Archives/` and under `build/release/<version>-<build>/`, where
`<build>` is the build in `system.txt`. See [tutorial 11](docs/tutorial/11-crash-reporting.md#reading-a-report-you-receive) for the steps.

## Opening in Xcode

`open SceneIt.xcodeproj`, choose the **SceneIt** scheme, then press Run. New Swift
files placed under `SceneIt/` are picked up automatically, so you never need to edit
the project file to add sources.
