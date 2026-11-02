# 01 — Project anatomy

How the repository builds into a Mac app, explained for someone who knows Cargo.

## Two build systems, one repo

```
Package.swift              SwiftPM manifest: the SceneItCore library (no UI)
Sources/SceneItCore/       library sources
Tests/SceneItCoreTests/    library tests: `swift test`
SceneIt.xcodeproj/         Xcode project: the app target and its tests
SceneIt/                   app sources (SwiftUI/AppKit)
SceneItTests/              app tests, run inside the running app
Config/Info.plist          the app's hand-written Info.plist keys
scripts/check.sh           the commit gate
```

SwiftPM is roughly Cargo. It can build libraries and command-line executables,
but it can't build a Mac **app**. An app is a signed directory with a fixed layout
(see below), and only Xcode's build system (`xcodebuild`) assembles one. So the
app is an Xcode project, and everything that doesn't need a view lives in a
SwiftPM library that the app depends on ([ADR 0002](../decisions/0002-project-structure.md)).
This is like a Cargo workspace where the binary crate needs a special bundler
(similar to `cargo-bundle`), except here the bundler is the IDE's build system.

## `Package.swift` vs `Cargo.toml`

[`Package.swift`](../../Package.swift) is Swift code that builds a `Package` value.

| Cargo | SwiftPM |
| --- | --- |
| `[package] name` | `Package(name:)` |
| `[lib]` | `.library(name:targets:)` product plus a `.target` |
| `tests/` integration tests | `.testTarget`, in `Tests/<Name>/` by convention |
| `edition = "2024"` | `swiftLanguageModes: [.v6]` |
| `rust-version` / target triple | `platforms: [.macOS(.v26)]`, the minimum OS (the deployment target) |
| `#![deny(warnings)]` | `.treatAllWarnings(as: .error)` in `swiftSettings` |
| `Cargo.lock` | `Package.resolved`. It doesn't exist yet because we have no dependencies. |
| `pub` / `pub(crate)` | `public` / `internal` (the default) |

A **product** is what other packages can consume. A **target** is a module (a
crate). `@testable import SceneItCore` lets a test see `internal` items, the
way a `#[cfg(test)] mod tests` sees private items.

Swift 6 language mode turns on *complete* data-race checking at compile time.
It's the closest analogue to `Send`/`Sync` enforcement: sharing mutable state
across concurrency domains is a compile error.

## The Xcode project

[`SceneIt.xcodeproj/project.pbxproj`](../../SceneIt.xcodeproj/project.pbxproj)
is an old NeXTSTEP-style property list. The key objects:

- **Target** (`PBXNativeTarget`): one product. Here that's `SceneIt` (product
  type *application*) and `SceneItTests` (a *unit-test bundle*). A target is like a
  Cargo target (`[[bin]]`, `[lib]`), plus a list of build phases (compile sources,
  link frameworks, copy resources).
- **Build settings** (`XCBuildConfiguration`): `KEY = value` pairs, set per
  configuration (`Debug`/`Release`, roughly Cargo profiles). They're layered:
  the project level is the default, and the target level overrides it.
  `xcodebuild -showBuildSettings` prints the resolved values. Ours:
  - project level (shared): `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`,
    `MACOSX_DEPLOYMENT_TARGET = 26.0`, `SWIFT_TREAT_WARNINGS_AS_ERRORS` and
    `GCC_TREAT_WARNINGS_AS_ERRORS` (for C/Obj-C, which we don't have yet),
    `MARKETING_VERSION = 0.1.0`, and ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`).
  - app target: `PRODUCT_NAME = "Scene It"` (the bundle and executable name, with
    the space), `PRODUCT_MODULE_NAME = SceneIt` (the Swift module, which can't
    contain a space), `PRODUCT_BUNDLE_IDENTIFIER = com.samitbasu.SceneIt`,
    `ENABLE_HARDENED_RUNTIME = YES`.
- **Synchronized folders** (`PBXFileSystemSynchronizedRootGroup`): the target
  compiles whatever is in `SceneIt/`, like Cargo picking up `src/`.
  Older projects listed every file in the pbxproj, which caused merge conflicts.
  Adding, renaming or deleting a `.swift` file under `SceneIt/` or `SceneItTests/`
  doesn't touch the pbxproj. Non-Swift files in those folders become *resources*
  copied into the bundle. That's why `Info.plist` lives in `Config/`: inside
  `SceneIt/` it would be copied a second time and the build would fail with
  "Multiple commands produce".
- **Local package reference** (`XCLocalSwiftPackageReference`, `relativePath = .`):
  the app links the `SceneItCore` product, like a `path = ".."` dependency.
- **Scheme** ([`SceneIt.xcscheme`](../../SceneIt.xcodeproj/xcshareddata/xcschemes/SceneIt.xcscheme)):
  says which targets to build for each *action* (Run, Test, Profile, Archive) and
  in which configuration. Cargo has no equivalent because `cargo test` hard-codes
  the answer. `xcodebuild -scheme SceneIt test` builds the app, builds
  `SceneItTests`, launches the app and runs the tests inside it. The scheme is in
  `xcshareddata/` so it's committed. Per-user schemes go in the ignored `xcuserdata/`.

## The app bundle

A `.app` is a directory that Finder shows as one file. This is our Debug build
(`build/DerivedData/Build/Products/Debug/Scene It.app`):

```
Scene It.app/
└── Contents/
    ├── Info.plist                 metadata, merged at build time (below)
    ├── PkgInfo                    legacy type/creator code: APPL????
    ├── MacOS/
    │   ├── Scene It               the executable (Debug: a small launcher stub)
    │   ├── Scene It.debug.dylib   Debug only: the real code, for SwiftUI previews
    │   └── __preview.dylib        Debug only: the previews hook
    └── _CodeSignature/
        └── CodeResources          hashes of every file in the bundle
```

A Release build has just `MacOS/Scene It`. Later, resources (icons, asset
catalogs) go in `Contents/Resources/`, and embedded frameworks go in
`Contents/Frameworks/`. `SceneItCore` is linked statically into the executable,
so it doesn't appear as a separate file. When the tests run, Xcode also copies
`SceneItTests.xctest` into `Contents/PlugIns/`, and the app loads it at launch.

## `Info.plist`

The bundle's manifest: identifier, version, executable name, minimum OS,
and the file types the app handles. Most keys are generated from build
settings (`GENERATE_INFOPLIST_FILE = YES`, plus `INFOPLIST_KEY_*` settings).
Keys that can't be expressed that way are written in
[`Config/Info.plist`](../../Config/Info.plist), and the build merges both into
`Contents/Info.plist`. `$(PRODUCT_BUNDLE_IDENTIFIER)` in that file is expanded at
build time, so the book type is always `<bundle id>.book`. Check the result with:

```sh
plutil -p "build/DerivedData/Build/Products/Debug/Scene It.app/Contents/Info.plist"
```

## UTIs and the `.sceneit` package

A **Uniform Type Identifier** names a file type and places it in a conformance
hierarchy, a bit like a trait hierarchy: `public.png` conforms to `public.image`,
which conforms to `public.data`. ([ADR 0004](../decisions/0004-book-is-a-package.md))

`Config/Info.plist` does two things:

1. **Exports** `com.samitbasu.SceneIt.book` (`UTExportedTypeDeclarations`). It
   says that we own this type, that files ending in `.sceneit` have it, and that
   it conforms to `com.apple.package` and `public.composite-content`.
   `com.apple.package` is the important one: Finder shows any *directory* of this
   type as a single opaque document. "Show Package Contents" still opens it.
   `.app` bundles work the same way.
2. **Claims** the type (`CFBundleDocumentTypes`): role `Editor` (we read and
   write it), `LSHandlerRank = Owner` (we're the primary app for it, so
   double-clicking opens Scene It), and `LSTypeIsPackage`.

In code, [`SceneIt/BookType.swift`](../../SceneIt/BookType.swift) declares
`UTType.sceneItBook` with `UTType(exportedAs:)`, which reads the declaration
from the app's own bundle. [`SceneItTests/BookTypeTests.swift`](../../SceneItTests/BookTypeTests.swift)
checks that the Swift constant and the plist agree.

The system learns about the types an app declares through **Launch Services**,
a per-user database that's updated when an app is launched or copied into
`/Applications`. Lookups that go through that database (for example,
`UTType(filenameExtension: "sceneit")`) depend on which builds of Scene It have
been registered, so tests shouldn't rely on them.

## Signing and the hardened runtime

Every Mac executable must be code-signed. Without a certificate we use **ad-hoc**
signing (`CODE_SIGN_IDENTITY = "-"`), which seals the bundle's contents but proves
nothing about who signed it. A Developer ID identity comes in issue #3 ([ADR 0001](../decisions/0001-distribution-developer-id.md)).

The **hardened runtime** is a signing flag that makes the OS refuse code
injection, unsigned libraries, and writable+executable memory unless the app
holds an entitlement for each one. Notarization requires it, and Developer ID
distribution requires notarization. We turn it on now so that anything
incompatible with it (a dependency that needs JIT, an unsigned plugin) breaks
on day one, not on release day.

Caveat: Xcode drops the flag for **ad-hoc Debug** builds and prints
`note: Disabling hardened runtime with ad-hoc codesigning.` Release builds
keep it. You can see this with
`codesign -dv "…/Scene It.app"`. Release prints `flags=0x10002(adhoc,runtime)`,
Debug prints `flags=0x2(adhoc)`. Once we sign with a real identity, Debug will
be hardened too.

## The gate: `scripts/check.sh`

[`scripts/check.sh`](../../scripts/check.sh) is our `cargo fmt --check && cargo clippy -D warnings && cargo test` ([ADR 0008](../decisions/0008-local-ci.md)).
It prints nothing and exits 0 when green. Otherwise it prints the failing
step's diagnostics and exits 1. Full logs are in `build/check/`.

| Step | Cargo analogue |
| --- | --- |
| grep for `layoutManager` under `SceneIt/` and `Sources/` | a custom lint: touching it silently switches a text view to TextKit 1 (PLAN §2) |
| `swift format lint --strict` with [`.swift-format`](../../.swift-format) | `cargo fmt --check` (plus a few style lints) |
| `swift test` | `cargo test` for the library |
| `xcodebuild … build test` | `cargo build && cargo test` for the app, warnings as errors |

There is no clippy equivalent. The compiler's warnings, promoted to errors, are
the lint. [`scripts/format.sh`](../../scripts/format.sh) is `cargo fmt`.
