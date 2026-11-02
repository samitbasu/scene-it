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
- For releases only: an Apple Developer Program team, a *Developer ID Application*
  certificate, and a stored `notarytool` profile named `scene-it-notary` (issue #3)

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
scripts/                   the scripts below; lib.sh holds what they share
docs/                      decisions, workflow, tutorials
build/                     all build output (git-ignored)
dist/                      release artifacts (git-ignored)
```

## Scripts

All scripts are run from the repository root, use `bash` with `set -euo pipefail`,
and exit non-zero on failure. **Status** shows whether a script exists yet. A
script marked *planned* lands with the issue named, and its section is updated
from the real behaviour when it merges.

### `scripts/check.sh`: the commit gate

**Status:** available.

```sh
scripts/check.sh
```

Takes no arguments. The Swift paths it checks are `Package.swift`, `Sources/`,
`Tests/`, `SceneIt/` and `SceneItTests/`. They're defined once in `scripts/lib.sh`,
which both scripts source. It first deletes `build/check/SceneIt.xcresult`, then
runs, in order, stopping at the first failure:

1. **TextKit 1 guard:** fails if any `.swift` file in those paths matches
   `\blayoutManager\b|NSLayoutManager|usingTextLayoutManager: *false`.
   `textLayoutManager` is allowed. It also fails if one of the paths is missing.
2. `swift format lint --strict --recursive` over those paths, using `.swift-format`.
3. `swift test` (SceneItCore unit tests; build output in `.build/`).
4. `xcodebuild -project SceneIt.xcodeproj -scheme SceneIt -destination 'platform=macOS'
   -derivedDataPath build/DerivedData -resultBundlePath build/check/SceneIt.xcresult test`.
   This builds the app and runs the app-hosted tests. Compiler warnings are errors,
   through the project's build settings and the package manifest. Linker warnings
   are not fatal.

**Output on success:** nothing, exit status 0.

**Output on failure:** exit status 1, and on stderr:
`check.sh: <step> failed (full log: build/check/<step>.log)`, followed by the
`error:`/`warning:`/`✘` lines from that log, or its last 50 lines if none match.
Only when the xcodebuild step fails, each failing test from that run's result
bundle is also listed as `✘ <target>/<test>: <failure text>`.

**Products:** one log per step in `build/check/` (`textkit1-guard.log`, `lint.log`,
`swift-test.log`, `xcodebuild.log`), the test result bundle
`build/check/SceneIt.xcresult` (open it in Xcode), and the built app at
`build/DerivedData/Build/Products/Debug/Scene It.app`. All of `build/` can be
deleted at any time. Run this before every commit; nothing lands on `main`
without it passing.

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

### `scripts/release.sh`: build a distributable app

**Status:** planned, lands with #4. Needs #3 (Developer ID) for the default mode.

```sh
scripts/release.sh                 # signed, notarized, stapled DMG
scripts/release.sh --unnotarized   # ad-hoc-signed zip for friendly testers only
```

**Default mode:** archive → export with Developer ID → notarize (`notarytool`,
profile `scene-it-notary`) → staple → build a DMG → notarize and staple the DMG.

**Output:**
- `dist/Scene It <version>.dmg`, which opens on any Mac running macOS 26 or later
  without Gatekeeper warnings. Verify with `spctl -a -vvv -t install "dist/Scene It <version>.dmg"`,
  which should report *Notarized Developer ID*.
- `build/release/`, which holds the intermediate `.xcarchive`, the exported app
  and the notarization logs.

The version comes from `MARKETING_VERSION`; the build number is the git commit count.

**`--unnotarized`:** a stopgap for when the Developer ID account isn't active.
**Output:** `dist/Scene It <version>-unnotarized.zip`, which contains the app and a
`README.txt` telling the tester to allow the app the first time it's blocked, via
**System Settings → Privacy & Security → Open Anyway**.

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

Release builds need their dSYM to symbolicate (`atos`), and `scripts/release.sh` must archive
it. See [tutorial 11](docs/tutorial/11-crash-reporting.md#reading-a-report-you-receive) for the steps.

## Opening in Xcode

`open SceneIt.xcodeproj`, choose the **SceneIt** scheme, then press Run. New Swift
files placed under `SceneIt/` are picked up automatically, so you never need to edit
the project file to add sources.
