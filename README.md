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

**Status:** lands with #2 (in review).

```sh
scripts/check.sh
```

Takes no arguments. Runs, in order, stopping at the first failure:

1. `swift format lint --strict` over `Sources/`, `Tests/`, `SceneIt/`, `SceneItTests/`
2. `swift test` (SceneItCore unit tests)
3. `xcodebuild -scheme SceneIt build test`, with warnings treated as errors
4. A guard that fails if `layoutManager` (the TextKit 1 API) appears in the app sources

**Output:** nothing but a final success line when everything passes. On failure,
it prints the failing step's output. Build products go to `build/` (DerivedData),
which you can delete at any time. Run this before every commit; nothing lands on
`main` without it passing.

### `scripts/format.sh`: apply formatting

**Status:** lands with #2 (in review).

```sh
scripts/format.sh
```

Takes no arguments. Rewrites Swift files in place using `.swift-format`, the same
rules `check.sh` lints against. **Output:** modified source files only; review them
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
