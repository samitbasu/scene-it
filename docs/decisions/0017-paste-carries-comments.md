# 0017 — Pasting commented text brings its comments along

**Status:** Accepted (2026-11-01)

Copy, cut and paste within Scene It use an app-specific pasteboard type that carries the
full attributed text plus the referenced comments (text, color, date).

- **Pasting into the same scene** while the original comment still exists keeps the original id,
  so cut then paste is lossless.
- **Pasting into another scene** (or after the original was dismissed) creates a *copy* of each
  comment with a fresh id in the destination scene. The source scene is untouched.
- **Comment ids the destination can't resolve** are never written: they're remapped or stripped
  before the store accepts the edit, so a paste can never make a save fail validation.
- **Pasting from other apps** goes through plain or RTF text, with no comments.
