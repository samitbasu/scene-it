# 0008 — Local check script instead of hosted CI

**Status:** Accepted (2026-11-01)

`scripts/check.sh` is the gate for every commit and PR, whether made by agents or
humans. It runs `swift format lint --strict`, `swift test`, and `xcodebuild build
test` with warnings treated as errors. Hosted CI can run the same script later.

## Amendment (2026-11-09, #151): when the gate builds from clean

The gate's builds are incremental, except that `check.sh` deletes `build/DerivedData` or
`.build/` first when that folder's inputs have changed since it was built. The inputs are the
toolchain (Xcode, the macOS SDK build and Swift), plus `Package.swift`, `SceneIt.xcodeproj`
and `Config/` for `build/DerivedData`, and `Package.swift` for `.build/`. Each folder keeps a
hash of them in `scene-it-build-inputs`. A clean build costs about 30 s per folder on this
machine, against about 3 s for an unchanged incremental one, so the gate pays it only when
the build graph or the toolchain changes.

### Why
A persistent gate worktree went wrong twice in one day:
- **A new SDK.** A tree that no longer compiled against the updated SDK (an unavailable
  `Sendable` conformance) passed, because nothing recompiled the file that broke.
- **A package-graph change.** #156 made `SceneItTestSupport` depend on `SceneItCore`. Xcode
  then builds `SceneItCore` as a dynamic framework under
  `Build/Products/Debug/PackageFrameworks/` instead of a static object. The old static
  product's `Build/Products/Debug/SceneItCore.swiftmodule` stays behind. It's on the app's
  search path, the dependency scan finds it first, and the app compiles against the old
  interface: "cannot find type 'MinuteTicker' in scope" for every type the merge added, while
  `swift test` passed. Reproduced by building 34242c3 and then 31fb9ef in one derived data
  folder; deleting only that stale module fixed it. New files in an unchanged package graph
  build incrementally without trouble.

### Alternatives
- **Hash the list of source files.** Most PRs add files, so most gates would build from
  clean, and a new file isn't what breaks the build; a change to the manifest or project is.
- **Delete only the stale module.** Fixes this one case. The next shape change (a product
  that becomes static again, a target that moves) can leave a different leftover.
- **A `--clean` flag.** Needs someone to know when to pass it, which is exactly what went wrong.
- **Always build from clean.** Correct, but about a minute more of build work on every run.

### Learning notes
Xcode's incremental build tracks files and build settings, not "what used to be here":
products of a configuration that no longer exists aren't deleted, and anything on a search
path still resolves. Cargo has the same shape of problem (`target/` survives toolchain
upgrades), which it handles by keying its fingerprints on the rustc version.
