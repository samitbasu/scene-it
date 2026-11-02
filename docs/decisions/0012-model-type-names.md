# 0012 — Model types avoid SwiftUI names

**Status:** Accepted (2026-11-01)

## Decision
Rename the model types that collide with SwiftUI and AppKit types:

| Was | Now |
| --- | --- |
| `Scene` | `BookScene` (and `SceneID` stays, since it doesn't collide) |
| `Settings` | `BookSettings` |
| `TextField` (validator location) | `SceneTextPart` |

The JSON keys (`scenes`, `settings`, …) are unchanged; this only renames Swift types.

## Alternatives
- **Keep `Scene` behind an app-level typealias:** stays closer to PLAN's vocabulary, but needs a typealias and a `SwiftUI.Scene` qualifier.
- **Qualify at every use site:** noisy, with confusing errors whenever a qualifier is forgotten.

## Learning notes
Swift has no per-file `use` list. `import M` makes all of M's public names visible
unqualified in that file, and a name defined in two imported modules is "ambiguous for
type lookup" until it's qualified (`SwiftUI.Scene`). Rust would make you pick at the `use`
site; Swift makes you pick at the *use*. Avoiding the collision up front is the cheap fix.
