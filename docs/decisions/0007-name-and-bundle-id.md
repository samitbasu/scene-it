# 0007 — Name and bundle identifier

**Status:** Accepted (2026-11-01). Resolves PLAN Q2.

- Display name: **Scene It**
- Bundle id: **`com.samitbasu.SceneIt`**
- Book UTI: `com.samitbasu.SceneIt.book`, extension `.sceneit`
- Swift module names: `SceneIt` (app), `SceneItCore` (package)

The bundle id is permanent once shipped. Preferences, Application Support paths
and the notarization history all key off it.
