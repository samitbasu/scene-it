# 0004 — A book is a `.sceneit` package

**Status:** Accepted (2026-11-01). **Deviates from PLAN §5.1** (plain folder). The JSON format is unchanged.

## Decision
A book is a directory named `My Novel.sceneit`, declared in `Info.plist` as an
exported UTI (`com.samitbasu.SceneIt.book`) that conforms to `com.apple.package`.
Finder shows it as a single document, and double-clicking it opens Scene It. Its
contents are exactly PLAN §5.1, plus `Backups/` from [0005](0005-backups.md).

We do **not** use `NSDocument`/`DocumentGroup`. `BookStore` owns all I/O so that
the plan's save pipeline (validate → rotate → atomic write) is explicit and testable.

## Learning notes
- A **UTI** (Uniform Type Identifier) is macOS's type system for files, with conformance (inheritance) between types. Declaring that our type conforms to `com.apple.package` is what makes Finder treat the directory as one opaque file.
- "Show Package Contents" in Finder still exposes the inside, which keeps manual recovery possible.
