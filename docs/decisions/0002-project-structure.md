# 0002 — Xcode app target + local SwiftPM package

**Status:** Accepted (2026-11-01)

## Decision
```
Package.swift            SceneItCore — model, RunCodec value logic, persistence,
Sources/SceneItCore/      backups, archive, search, crash-report bundling.
Tests/SceneItCoreTests/  `swift test` runs these: fast, no app host.
SceneIt.xcodeproj        Thin app target: SwiftUI/AppKit UI only. Uses Xcode 16+
SceneIt/                 *synchronized folders*, so adding a file never edits the pbxproj.
SceneItUITests/ (later)  UI tests through xcodebuild.
```
Anything that doesn't need AppKit views belongs in `SceneItCore`. `SceneItCore`
may import Foundation (and AppKit only where text attributes require it, such as
`NSColor` in the codec).

## Alternatives
- **Single Xcode target:** every unit test runs inside an app host, which is slow, and nothing enforces the model/UI boundary.
- **XcodeGen:** a third-party tool. Synchronized folders already remove its main benefit.

## Learning notes
- A SwiftPM package is the closest thing to a Cargo crate: `Package.swift` is `Cargo.toml` written in Swift. `swift build` and `swift test` work like `cargo build` and `cargo test`.
- Apps can't be built by SwiftPM alone. An `.app` is a *bundle* (a directory with `Info.plist`, `Contents/MacOS/<binary>`, resources, and a signature), and Xcode's build system assembles it.
- `public` matters: like Rust's `pub`, anything the app uses from `SceneItCore` must be `public`. The default is `internal`, which is roughly `pub(crate)`.
