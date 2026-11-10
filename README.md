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
| [`site/`](site/) | The download website (see [Website](#website)) |
| [`LICENSE`](LICENSE) | MIT License |

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
site/                      the download website: index.html, style.css, images/
.github/workflows/         pages.yml, which deploys site/ to GitHub Pages
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
| `just test ARGS` | `scripts/fresh-build.sh .build swift test ARGS` (SceneItCore) |
| `just test-app ARGS` | `scripts/fresh-build.sh build/DerivedData xcodebuild … -derivedDataPath build/DerivedData test ARGS` (the app-hosted tests, as the gate runs them) |
| `just test-filter PATTERN ARGS` | `scripts/fresh-build.sh .build swift test --filter PATTERN ARGS` |
| `just coverage ARGS` | `scripts/coverage.sh ARGS` |
| `just fuzz-page SEEDS=8 STEPS=1500` | the longer page fuzz (below), e.g. `just fuzz-page 16 3000` |
| `just corpus-regenerate` | `CORPUS_REGENERATE=1 scripts/fresh-build.sh .build swift test --filter CorpusConformance` (`Tests/Corpus/README.md`), then a reminder to review the diff |
| `just build ARGS` | `scripts/fresh-build.sh build/DerivedData xcodebuild … -derivedDataPath build/DerivedData build ARGS` (Debug) |
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
runs steps 1–6 in order, stopping at the first failure. If they pass, it runs steps 7 and 8
at the same time and waits for both:

1. `scripts/test-guards.sh` and `scripts/test-lib.sh` (below): check that the source guards
   in steps 2–5 reject and accept what they should, and that the gate's own helpers
   (the stale-build check and the cleanup on a timeout or an interrupt) work.
2. **TextKit 1 guard:** fails if any `.swift` file in those paths matches
   `\blayoutManager\b|NSLayoutManager|usingTextLayoutManager: *false`.
   `textLayoutManager` is allowed, and so is `SceneItTests/TextKit1Alarm.swift`, the test alarm that
   names the notification a text view posts as it falls back to TextKit 1, to fail any page test on it.
3. **Logging guard:** fails on `Logger(`, `os_log`, `OSLog…` or `NSLog(` outside
   `Sources/SceneItCore/Diagnostics/Log.swift` and `CurrentProcessLog.swift`. All logging
   goes through `Log`, whose types keep manuscript text out (ADR 0006).
4. **Trap-message guard:** fails on string interpolation (`\(`) on the same line as
   `fatalError(`, `precondition(`, `preconditionFailure(`, `assert(` or `assertionFailure(`.
   Crash reports, which problem reports include verbatim, quote these messages.
5. **Exit-test guard:** fails on `processExitsWith`, `exitsWith:` or `ExitTest`. A Swift
   Testing exit test's child process launches as the real app, against the owner's real data (#120).

   Steps 2–5 are functions in `scripts/guards.sh`, listed once in its `source_guards`. Each one fails if a path is missing,
   ignores lines that are only a `//` comment, and prints `file:line: error: <rule>: <line>`
   for each hit.
6. `swift format lint --strict --recursive` over those paths, using `.swift-format`.
7. `swift test` (SceneItCore unit tests; build output in `.build/`).
8. `xcodebuild -project SceneIt.xcodeproj -scheme SceneIt -destination 'platform=macOS'
   -derivedDataPath build/DerivedData -resultBundlePath build/check/SceneIt.xcresult test`.
   This builds the app and runs the app-hosted tests. Compiler warnings are errors,
   through the project's build settings and the package manifest. Linker warnings
   are not fatal.

Steps 7 and 8 share no files: SwiftPM builds `SceneItCore` into `.build/`, and xcodebuild
builds its own copy into `build/DerivedData`. Running them together saves about 40–50 s on
an incremental build on a quiet machine, and less when the machine is busy.

**Stale builds:** before steps 7 and 8, check.sh deletes a build folder it can't trust, so
that step builds from clean (ADR 0008). Otherwise the builds are incremental. A clean build
adds about 30 s to each of steps 7 and 8. A folder is trusted when its `scene-it-build-inputs`
record matches its inputs, and its build database (`…/XCBuildData/build.db`) is no newer than
that record. A folder with build output but no database at that path isn't trusted, so a
change of build system that moves the database shows up as a clean build on every run, never
as a check that silently stops working.

- The inputs are the toolchain (`xcodebuild -version`, the macOS SDK's build version and
  `swift --version`), plus `Package.swift`, `SceneIt.xcodeproj` and `Config/` for
  `build/DerivedData`, and `Package.swift` for `.build/`. Within those, only files that git
  tracks or doesn't ignore count, and never `xcuserdata`. A tracked file deleted from the
  working tree counts as deleted.
- The record is rewritten whenever the folder is cleared. It's touched after each of the gate's
  builds, and after each `fresh-build.sh` build (below). A build into the folder by any other
  route leaves the database newer, so the next gate builds from clean. Other routes include a
  plain `swift test` or `xcodebuild`, a gate that was interrupted, and a build step that ran out
  of time.
- From the check to the end of the build, the gate holds a lock on each folder:
  `build/locks/lock-<folder>`, a symbolic link to the gate's process ID. A `fresh-build.sh`
  build of the same folder takes the same lock, so neither can delete the folder under the
  other. Whichever comes second fails with
  `stale-build check failed: <folder> is in use by process <pid>: <command>`. A lock whose
  process has exited is taken over, so a killed gate never blocks the next one. If the
  process ID has been reused by another process, delete the link.
- If the folder is stale but a `Scene It.app` built in it is running, check.sh doesn't delete
  it. It leaves the folder unrecorded, and fails with
  `check.sh: stale-build check failed: <folder> is stale, but Scene It.app is running from it.
  Quit the app, then run the gate again.`
- If the check itself fails (no toolchain, or not in a git checkout), check.sh prints
  `check.sh: stale-build check failed: <reason>` and exits 1.

Each step has a wall-clock limit: 5 minutes for steps 1–6, 15 for `swift test`, 45 for
xcodebuild. A step still running at its limit fails. Swift Testing's own time limits can't
end a test that's blocked, so without this a hung test hangs the gate (#77). At the limit,
check.sh kills two sets of processes: the step's own process tree, and any process that runs
something from the step's own build folder (`.build/` for `swift test`, `build/` for
xcodebuild, either for steps 1–6), started while the step ran, and isn't `Scene It.app`.
That spares a Debug app or an IDE build that was already running, and an app the step didn't
start itself. So a timeout in one of steps 7 and 8 never kills the other. Before it kills
them, check.sh samples up to four of them that are test runners (`swiftpm-testing-helper`,
an `.xctest` bundle or a test host app), all at once, for 3 seconds, into
`build/check/<step>-hang-<pid>.txt`. It then stops each one (`SIGSTOP`), lists them again
until no new process turns up, and only then kills them all, so none can start a child that
outlives the kill.

**Interrupted** (Ctrl-C, `SIGTERM` or `SIGHUP`): check.sh kills everything it started, in the
same way, then dies of the same signal, so a calling shell or loop sees the interrupt (status
130, 143 or 129). No step keeps running in the background. A test-host `Scene It.app` outside the gate's
own process tree is spared on purpose: it might be the writer's own Debug run.

**Output on success:** nothing, exit status 0.

**Output on failure:** exit status 1, and on stderr, for each failed step:
`check.sh: <step> failed (full log: build/check/<step>.log)`, followed by the
`error:`/`warning:`/`✘` lines from that log, or its last 50 lines if none match. Steps 7
and 8 don't stop at the first failure: each failed one is reported. `swift-test`'s report
prints as soon as it ends; xcodebuild's prints once both have finished.
A step that ran out of time adds `error: still running after <n> min (or s), so it was killed: <command>`
and the path of the samples. Only when the xcodebuild step fails, each failing test from
that run's result bundle is also listed as `✘ <target>/<test>: <failure text>`.

**Products:** one log per step in `build/check/` (`guard-tests.log`, `lib-tests.log`, `textkit1-guard.log`,
`logging-guard.log`, `trap-message-guard.log`, `exit-test-guard.log`, `lint.log`, `swift-test.log`, `xcodebuild.log`), the test result bundle
`build/check/SceneIt.xcresult` (open it in Xcode), and the built app at
`build/DerivedData/Build/Products/Debug/Scene It.app`, and each build folder's
`scene-it-build-inputs` (above). All of `build/` except
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

### `scripts/test-lib.sh`: tests for the gate's helpers

**Status:** available.

```sh
scripts/test-lib.sh
```

Takes no arguments; `check.sh` runs it after `test-guards.sh`. It checks the stale-build
check from `scripts/lib.sh` (`prepare_build`, `record_build`) on a fixture git checkout in a
temporary directory:
- A build folder is kept when nothing changed, or when only `xcuserdata`, an ignored file or a
  file outside the inputs changed.
- It's cleared when an input changes, a file is added to or renamed in an input directory,
  the toolchain changes, the record is gone, or a build skipped `record_build`.
- It's also cleared when its build database is missing, or when a tracked input is deleted
  without being staged. The deletion is hashed, not reported as an error.
- A stale folder that a running `Scene It.app` was built in is kept and left unrecorded. The
  gate's check fails, telling you to quit the app. `fresh-build.sh`'s check warns and goes on.
- A live lock holder keeps a second build out, and the error names its process ID. A lock
  whose holder has exited is taken over. `unlock_builds` releases only this shell's own locks.
- A failure (no toolchain, no git checkout, an unknown folder) is reported as
  `stale-build check failed`.

It also checks `kill_doomed` against a process that starts a `sleep` every 10 ms, both from inside
the tree (as an interrupted gate does, which must survive the call) and from outside it (as a
timeout does). Nothing in the tree may be left running, and neither may a build product started
after the snapshot. Three processes must be left running and not stopped: a process outside the
tree, a build product that was already running, and a `Scene It.app`. The stand-in build products
are symbolic links to `sleep` under the fixture's `build/`. Takes about 5 seconds. **Output:**
nothing on success. On failure, one `✘` line per failed check, and exit status 1.
**Products:** none; the fixtures are deleted and any leftover `sleep` is killed on exit.

### `scripts/fresh-build.sh`: build into a folder the gate can trust

**Status:** available.

```sh
scripts/fresh-build.sh build/DerivedData xcodebuild -project SceneIt.xcodeproj -scheme SceneIt \
    -destination 'platform=macOS' -derivedDataPath build/DerivedData build
scripts/fresh-build.sh .build swift test --filter Corpus
```

The first argument is `build/DerivedData` or `.build`; the rest is the command that builds
into it. It takes the folder's lock and runs the gate's stale-build check on it (above), which
may delete the folder. Then it runs the command and records the build, so the next gate can
build on the folder incrementally. Unlike the gate, it only warns, and builds anyway, when the
folder is stale and a `Scene It.app` built in it is running (as after `just run`). The `just` recipes that build (`test`, `test-filter`, `test-app`, `fuzz-page`,
`corpus-regenerate`, `build` and `run`) and `coverage.sh`'s `swift test` all go through it.
**Output:** the command's, plus a message if the check fails or doesn't clear a stale folder.
Exits with the command's status, or 1 if the check fails (including when the gate or another
build holds the folder). **Products:** the command's, the folder's `scene-it-build-inputs`, and
a lock in `build/locks/` while it runs.

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
Core HTML: <repo>/build/coverage/core-html/index.html
App result bundle: <repo>/build/coverage/app.xcresult
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
the steps (never under two minutes). Those limits assume the scheme's cap of four hosted tests at
a time (ADR 0039). A run that doesn't take the scheme's test action (an explicit `.xctestplan`,
say) loses it; put `TEST_RUNNER_SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4` in front of the
command to restore it. **Output:** the test results; a failure lists the last
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
`searchCabinet` renders the File Cabinet scope (#34) into the same subfolder, over mockup 12's five
copies and beside `11-search-file-cabinet-range.png`: `search-cabinet-prompt`, `search-cabinet-all`,
`search-cabinet-range`, `search-cabinet-one-copy`, `search-cabinet-tags` (the copies' own tags) and
`search-cabinet-unreadable` (a copy whose file is gone); add
`-only-testing:SceneItTests/WindowRenders/searchCabinet\(\)`.

`readAloud` renders read aloud (#39, `ReadAloudRenders.swift`): `read-aloud-1-no-selection` (▶
dimmed), `read-aloud-2-selection` (▶) and `read-aloud-3-reading` (■, the sentence being read
highlighted), each at 1× and 2× with a `-close-up@2x.png` of the bar and the top of the page.
Nothing is heard. To render only these, add `-only-testing:SceneItTests/WindowRenders/readAloud\(\)`.

`commentUnderlines` renders comment underlines (#24, ADR 0032) on the page (`underlines`) and in
the Notes tab (`underlines-notes`), each as `@1x.png`, `@2x.png` and `-vs-mockup.png`.

`commentsPanel` renders the Comments tab (#25, `CommentsPanelRenders.swift`) into a `comments/`
subfolder: cards with one selected, the floating Comment button, the ⋯ menu on an anchored and
a detached card, `#red ferry` and an unknown color, a card being edited and the empty state,
each beside mockup 02, 03 or 04, with a `-panel@2x.png` close-up of the panel. An open `NSMenu`
can't be captured, so the ⋯ menu is the card's real menu, at its real size and place, drawn by
`MenuStandIn`: the items' titles, line samples, check mark, separator, key equivalent and enabled
state are the menu's own; the chrome, row heights and insets approximate macOS 26's. To render
only these, add `-only-testing:SceneItTests/WindowRenders/commentsPanel\(\)`.

`tagsTab` renders the Tags tab (#20, `TagsTabRenders.swift`) into a `tags/` subfolder as
`final-tags-<state>`: `mockup` (mockup 06's tags), `typing`, `no-tags-on-scene`, `long-tag`,
`many-tags`, `many-tags-end` (the list scrolled to its end) and `read-only`, at 1× and 2×, beside
`06-tags-tab.png`, with a `-panel@2x.png` close-up. To render only these, add
`-only-testing:SceneItTests/WindowRenders/tagsTab\(\)`.

`exportChooser` renders Export as SceneIt's scene chooser (#79, `ExportChooserRenders.swift`) into an
`export/` subfolder, with the sample book's 24 story scenes and four unticked: the shipped sheet
(`export-a-sheet`) and the alternative list sheet (`export-b-list-sheet`), each over the window at 1×
and 2× beside `14-file-a-copy-dialog.png`, with a `-dialog@3x.png` close-up; and the save-panel
accessory alternative alone (`export-c-panel-accessory`, 1× and 2×), since the system panel around it
can't be drawn offscreen. To render only these, add
`-only-testing:SceneItTests/WindowRenders/exportChooser\(\)`. `exportChooserNote` (#155) renders the
shipped sheet's notes about text Scene It couldn't read into the same subfolder. Over a book whose
second scene holds an `### Unparsed` line: `export-note-shown` (all ticked, so the scenes' line shows)
and `export-note-hidden` (that scene unticked). Over the same book with a line of the book's own too:
`export-note-both` (both lines) and `export-note-book` (the scene unticked, so only the book's line).
Each is at 1× and 2× beside `14-file-a-copy-dialog.png`, with a `-dialog@3x.png` close-up; add
`-only-testing:SceneItTests/WindowRenders/exportChooserNote\(\)`.

`scenesSheet` renders the Scenes sheet (#28, `ScenesSheetRenders.swift`) into a `scenes/` subfolder, at 1× and
2× and beside mockup 07, 08 or 09: the recommended look as `final-scenes-cards`, `final-scenes-cards-tagging`
(+ tag opened on a card), `final-scenes-filter`, `final-scenes-no-matches`, `final-scenes-light-table`,
`final-scenes-new-scene-title` (the title typed on a new card), `final-scenes-read-only` and `final-scenes-empty`;
and the look candidates the owner hasn't picked between, as `candidate-tag-always-field`,
`candidate-messages-plain-no-matches` and `candidate-messages-plain-empty`. To render only these, add
`-only-testing:SceneItTests/WindowRenders/scenesSheet\(\)`.

`fileCabinet` renders the File Cabinet sheet (#33, `FileCabinetRenders.swift`) into a `cabinet/` subfolder, at 1×
and 2× beside mockup 12, on mockup 12's day (Nov 1, 2026) with its five copies: `final-cabinet`,
`final-cabinet-selected`, `final-cabinet-tagging`, `final-cabinet-filters` (a date and a tag chosen),
`final-cabinet-search`, `final-cabinet-no-matches`, `final-cabinet-empty` and `final-cabinet-read-only`. To render
only these, add
`-only-testing:SceneItTests/WindowRenders/fileCabinet\(\)`. `filedCopy` renders a filed copy open read-only into the
same subfolder, beside mockup 13: `final-filed-copy` (the banner) and `final-filed-copy-menu` (Close's menu, drawn by
`MenuStandIn`); add `-only-testing:SceneItTests/WindowRenders/filedCopy\(\)`.

`boneyard` renders the Boneyard tray and the sheet's drags and keys (#29, `BoneyardRenders.swift`) into a
`boneyard/` subfolder, at 1× and 2× and beside mockup 07: `final-tray`, `final-tray-lit` (a card over the tray),
`final-restore-here` and `final-move-here` (the slot), `final-card-focused` (the arrow keys' focus ring),
`final-tray-open-scene`, `final-boneyard-scene-page` ("Boneyard ›" and the rail's B), `final-tray-light-table`,
`final-deleted-open-scene-page` (no scene open), `final-tray-empty` and `final-tray-read-only`; and the candidates
`candidate-tray-lit-dashed`, `candidate-restore-here-neutral` and `candidate-restore-on-hover`. To render only
these, add `-only-testing:SceneItTests/WindowRenders/boneyard\(\)`.

`reviewRenders` renders Review Book… (#80, `ReviewRenders.swift`) into a `review/` subfolder, at 1× and 2×:
the window over a review copy with a comment, with the shipped banner (`review-a-banner`) and two
alternatives laid over it (`review-b-tinted`, `review-c-plain`), each beside `13-read-only-filed-copy.png`;
and the start screen with Review Book… as a third button (`start-a-third-button`, shipped) or on a line of
its own (`start-b-own-line`). To render only these, add
`-only-testing:SceneItTests/WindowRenders/reviewRenders\(\)`. `reviewBookMenuRenders`, in
`BookStoreIntegrationTests`, draws the File menu on the start screen (`menu-review-book-start-screen`).

`reviewOutputRenders` renders Copy Review's and Save Review…'s look (#81, `ReviewOutputRenders.swift`) into a
`review-output/` subfolder, drawn by WebKit offscreen from the review format's worked example: for the shipped
look (`a-spec`) and two alternatives (`b-sans-boxed`, `c-underlined`), the standalone page with one item ticked
(`page-<x>@2x.png`) and the clipboard HTML in a plain message body (`email-<x>@2x.png`), and the three pages side
by side (`compare-pages.png`). To render only these, add
`-only-testing:SceneItTests/ReviewOutputRenders`. `reviewOutputMenuRenders`, in `BookStoreIntegrationTests`,
draws the File menu with a review open (`menu-copy-and-save-review`).

`print` renders Print (#35, `PrintRenders.swift`) into a `print/` subfolder: the first two pages of a sample
scene with eight comments (three on one line, two on another), as the print operation saves them to PDF, drawn at 2× (`portrait-page-<n>@2x.png` for
text only, `landscape-page-<n>@2x.png` for text with comments); and the print dialog's accessory alone, since the
system dialog around it can't be drawn offscreen (`accessory-text-only@2x.png`, `accessory-with-comments@2x.png`).
Each also has a `-vs-mockup.png` beside `15-print-dialog.png`. To render only these, add
`-only-testing:SceneItTests/WindowRenders/print\(\)`.

`wordComments` renders Export to Word's Include comments (#183, ADR 0048, `WordCommentsRenders.swift`) into a
`word-comments/` subfolder: the save panel's accessory alone, since the system panel around it can't be drawn
offscreen (`accessory-<state>`, `unticked` and `ticked`, at 1× and 2×); and
`sample-with-comments.docx`, the ferry scene with six comments (two overlapping, one across a paragraph break),
authored by the Mac account's name, to open in Word and Pages. To render only these, add
`-only-testing:SceneItTests/WindowRenders/wordComments\(\)`.

`oneBookPerProcessRenders` (ADR 0038, `OneBookRenders.swift`) renders into a `close-to-start/` subfolder, at
1× and 2×: the File menu with a book open (`file-menu-book-open`) and on the start screen
(`file-menu-start-screen`), each a `MenuStandIn` drawing of the real File menu under a stand-in menu bar; the
start screen after a close (`start-screen-after-close`, 1440 × 900 pt); and, as the app's own `NSAlert`, the
refusal (`refusal`), new-book refusal (`create-refusal`), lost-book (`book-lost`) and several-books alerts, with
the first book open (`several-books`) and with none open (`several-books-none-open`). It drives the app's own
store, so it runs in `BookStoreIntegrationTests`: to render only these, use
`-only-testing:SceneItTests/OneAtATime/BookStoreIntegrationTests/oneBookPerProcessRenders\(\)`.

`fixField` renders the Errors tab's fix field (#127, `FixFieldRenders.swift`) into a `fix-field/`
subfolder as `fix-field@1x.png` and `fix-field@2x.png`: the SwiftUI `TextField` it was, above the
`AdmittingTextField` it is now, holding the same long line at the panel's width, then both empty with their
placeholder. To render only this, add `-only-testing:SceneItTests/WindowRenders/fixField\(\)`.

`focusModeRenders` renders focus mode (#21, `FocusModeRenders.swift`) into a `focus-mode/` subfolder, at 1×
and 2× and 1440 × 900 pt, from the app's own window (its toolbar is the `Window` scene's, which the offscreen
hosting windows don't have), the page focused with a two-page formatted scene: `normal`, `focus` (the "Press
Esc…" hint as focus mode begins), `focus-vs-normal.png` side by side, and `normal-panel-collapsed` with
`focus-from-panel-collapsed`. It drives the app's own store, so it runs in `BookStoreIntegrationTests`: to
render only these, use `-only-testing:SceneItTests/OneAtATime/BookStoreIntegrationTests/focusModeRenders\(\)`.

`site` renders the website's screenshots (`SiteRenders.swift`) into a `site/` subfolder, at 2× only: `scenes`
(the Scenes sheet and the Boneyard tray), `comments` (a commented page with a card selected), `cabinet` (Search's
File Cabinet scope over five filed copies), `read-aloud` (two paragraphs being read) and `print` (the first page
printed with comments). The book is the Scenes sheet's sample with a page-long ferry scene and nine comments. To
render only these, add `-only-testing:SceneItTests/WindowRenders/site\(\)`; then see [Website](#website) for
copying them into `site/images/`.

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
<repo>/dist/Scene It 0.1.0-unnotarized.zip
<repo>/build/release/0.1.0-26-unnotarized/Scene It.xcarchive/dSYMs/Scene It.app.dSYM
~/Library/Developer/Xcode/Archives/2026-11-01/Scene It 0.1.0-26-unnotarized.xcarchive
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

## Website

**Status:** draft, not live. `site/` is one hand-written page (`index.html`, `style.css`, `images/`) with no
build step, no JavaScript and nothing loaded from other servers. It will be served by GitHub Pages at
**scene-it.net** once the repository is public and the steps below are done. To preview it, open
`site/index.html` in a browser.

**Download link.** The page's button points at
`https://github.com/samitbasu/scene-it/releases/latest/download/Scene-It.dmg`, which GitHub redirects to the
asset of that name in the newest release
([Linking to releases](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)).
`release.sh` names its DMG `dist/Scene It <version>.dmg`, with spaces, so every release must upload a copy named
`Scene-It.dmg`. The page's "Version 0.1.1" line is edited by hand at each release.

**Screenshots.** Render them with the `site` test (see [Rendering the window for
review](#rendering-the-window-for-review)), then copy them into `site/images/` as 256-colour PNGs, which keeps each
under 200 KB (ImageMagick, `brew install imagemagick`):

```sh
for name in scenes comments cabinet read-aloud print; do
    magick "/tmp/window-renders/site/$name@2x.png" -strip -dither None -colors 256 "PNG8:site/images/$name.png"
done
```

The app is light-only (`AppDelegate` sets the Aqua appearance), so there are no dark screenshots; the page itself
follows the reader's light or dark setting. `site/images/app-icon.png` is a stand-in (candidate 02, index cards)
until the final icon lands; replace it with the shipped icon at 384 × 384 px.

**Deployment.** [`.github/workflows/pages.yml`](.github/workflows/pages.yml) uploads `site/` with
`actions/configure-pages`, `actions/upload-pages-artifact` and `actions/deploy-pages`, on every push to `main`
that changes `site/`, or by hand (Actions → Pages → Run workflow). Until Pages is enabled it can't deploy: its
runs, including the one after this lands on `main`, fail harmlessly at `configure-pages`.

### Going live (once)

The order matters: GitHub asks for the domain to be added to the repository *before* the DNS records point at
it, and recommends verifying it first, so nobody else can claim it in between
([Managing a custom domain](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site),
[Verifying your custom domain](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/verifying-your-custom-domain-for-github-pages)).

1. **Make the repository public**, then **enable Pages**: Settings → Pages → Build and deployment → Source:
   **GitHub Actions**. Run the Pages workflow once (Actions → Pages → Run workflow); the site appears at
   `https://samitbasu.github.io/scene-it/`.
2. **Verify the domain** for your account (not the repository): profile picture → Settings → Pages → Add a
   domain → `scene-it.net`. GitHub shows a TXT record, named `_github-pages-challenge-samitbasu.scene-it.net`,
   with a value. Add it in Squarespace (step 4, type TXT, Name `_github-pages-challenge-samitbasu`), wait for it to
   resolve (`dig TXT _github-pages-challenge-samitbasu.scene-it.net +short`), then click Verify. Leave the record
   in place for good: removing it unverifies the domain.
3. **Set the custom domain**: repository Settings → Pages → Custom domain → `scene-it.net` → Save. With a
   GitHub Actions workflow this setting is what counts: GitHub ignores a `CNAME` file in that case
   ([Troubleshooting custom domains](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/troubleshooting-custom-domains-and-github-pages)).
   `site/CNAME` names the same domain as a record in the repository, and a branch source would read it if
   the source were ever switched.
4. **DNS at Squarespace Domains** (the registrar): Domains dashboard → `scene-it.net` → **DNS** in the side panel
   ([Edit your domain's DNS records](https://support.squarespace.com/hc/en-us/articles/360002101888-Edit-your-domain-s-DNS-records)).
   Every change asks for your password (and 2FA) again.
   1. **Delete the Squarespace Defaults** that claim the same names: the four `A` records on `@`
      (198.185.159.144, 198.185.159.145, 198.49.23.144, 198.49.23.145) and the `www` `CNAME` to
      `ext-cust.squarespace.com`
      ([the values](https://support.squarespace.com/hc/en-us/articles/360035485391-DNS-records-for-connecting-third-party-domains)).
      Squarespace's docs don't say whether custom apex `A` records may sit beside its defaults, but if both were
      kept, browsers would be sent to Squarespace's servers for some lookups, and a `www` `CNAME` can't share its
      name with another record. Deleting the defaults disconnects the domain from any Squarespace site and
      breaks Squarespace's PayPal Payment Links; nothing of ours uses either. Leave any email (`MX`, `TXT`)
      records alone. (**Add preset → Squarespace defaults** puts them back.)
   2. **Add custom records**
      ([DNS records for web hosting](https://support.squarespace.com/hc/en-us/articles/31119879125645-DNS-records-for-web-hosting)),
      with GitHub's current addresses (from *Managing a custom domain*, checked 2026-11-09):

      | Type | Name | Data |
      | --- | --- | --- |
      | A | `@` | 185.199.108.153 |
      | A | `@` | 185.199.109.153 |
      | A | `@` | 185.199.110.153 |
      | A | `@` | 185.199.111.153 |
      | AAAA | `@` | 2606:50c0:8000::153 |
      | AAAA | `@` | 2606:50c0:8001::153 |
      | AAAA | `@` | 2606:50c0:8002::153 |
      | AAAA | `@` | 2606:50c0:8003::153 |
      | CNAME | `www` | `samitbasu.github.io` |

      If Squarespace calls an IPv6 address invalid, enter it uncompressed, e.g.
      `2606:50c0:8000:0000:0000:0000:0000:0153`. Squarespace can't put a `CNAME` on `@`, which is why the apex uses
      `A`/`AAAA` records. Never add a wildcard (`*`) record: GitHub warns it invites domain takeovers.
   3. Check: `dig scene-it.net +noall +answer -t A`, `dig scene-it.net +noall +answer -t AAAA` and
      `dig www.scene-it.net +noall +answer` should show only GitHub's addresses. Squarespace's records have a 4-hour
      TTL; changes can take up to 24–48 hours.
5. **Turn on Enforce HTTPS** (Settings → Pages) once GitHub has issued the certificate; the box can take up to
   24 hours to become available.

**Apex or www?** Recommended: **`scene-it.net` (the apex) as the primary**, which is what `site/CNAME` names.
It's the shorter address to say and print, and with both sets of records above GitHub redirects
`www.scene-it.net` to it by itself. The cost is that the apex is pinned to GitHub's four IP addresses, which
GitHub could change one day (re-check them when something breaks); a `www` primary would follow GitHub through
its `CNAME` instead, and the apex would then redirect to `www`. Either works; changing later means editing the
Custom domain field and `site/CNAME`.

### Cutting a release for the site

```sh
scripts/release.sh                                   # dist/Scene It 0.1.1.dmg, notarized
cp "dist/Scene It 0.1.1.dmg" dist/Scene-It.dmg       # the name the site links to
shasum -a 256 dist/Scene-It.dmg | tee dist/Scene-It.dmg.sha256
gh release create v0.1.1 dist/Scene-It.dmg dist/Scene-It.dmg.sha256 \
    --title "Scene It 0.1.1" --notes "SHA-256: $(cut -d' ' -f1 dist/Scene-It.dmg.sha256)"
```

The file's own name becomes the asset's name. `gh release create v0.1.1 "dist/Scene It 0.1.1.dmg#Scene-It.dmg"`
would **not** work: the text after `#` is only the asset's display label
([gh release create](https://cli.github.com/manual/gh_release_create)), so the asset would keep the spaced name
and the site's link would fail. Publish the SHA-256 in the release notes and as the `.sha256` asset, so a reader
can check the download with `shasum -a 256 Scene-It.dmg`. Then update the version on the page.

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

## License

Scene It is released under the [MIT License](LICENSE). Copyright (c) 2026 Samit Basu.
