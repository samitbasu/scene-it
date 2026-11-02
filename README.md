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
scripts/                   the scripts below
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

Takes no arguments. Runs, in order, stopping at the first failure:

1. **TextKit 1 guard:** fails if the identifier `layoutManager` (whole word, so
   `textLayoutManager` is fine) appears in any `.swift` file under `SceneIt/` or
   `Sources/`.
2. `swift format lint --strict --recursive` over `Package.swift`, `Sources/`, `Tests/`,
   `SceneIt/`, `SceneItTests/`, using `.swift-format`.
3. `swift test` (SceneItCore unit tests; build output in `.build/`).
4. `xcodebuild -project SceneIt.xcodeproj -scheme SceneIt -destination 'platform=macOS'
   -derivedDataPath build/DerivedData -resultBundlePath build/check/SceneIt.xcresult build test`.
   This builds the app and runs the app-hosted tests. Warnings are errors through
   the project's build settings and the package manifest.

**Output on success:** nothing, exit status 0.

**Output on failure:** exit status 1, and on stderr:
`check.sh: <step> failed (full log: build/check/<step>.log)`, followed by the
`error:`/`warning:`/`✘` lines from that log, or its last 50 lines if none match.
If the xcodebuild step ran tests, each failing test is listed from the result
bundle as `✘ <target>/<test>: <failure text>`.

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
`Package.swift`, `Sources/`, `Tests/`, `SceneIt/` and `SceneItTests/` using
`.swift-format`, the same paths and rules `check.sh` lints against. Some lint
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

## Opening in Xcode

`open SceneIt.xcodeproj`, choose the **SceneIt** scheme, then press Run. New Swift
files placed under `SceneIt/` are picked up automatically, so you never need to edit
the project file to add sources.
