# 0018 — When the book changed on disk: ask, and keep both versions

**Status:** Accepted (2026-11-01)

When a save finds that `book.json` was changed by something other than this
window (a sync service, another Mac, another copy of the app):

1. Autosave pauses, and the status bar shows "Changed on disk".
2. An alert explains what happened and offers two choices:
   - **Keep My Version:** save with `ExternalChangePolicy.overwriteKeepingTheirsAsBackup(theirs:)` (bound to the digest of the version the writer saw; a different version pauses and asks again). Mine
     becomes `book.json`, and theirs is rotated into `book.json.bak1`.
   - **Open Other Version:** first save my in-memory book as a new package
     next to the original, "<Title> (my edits).sceneit" (with a numeric suffix if needed), then
     reopen the original package from disk.
3. Either way, both versions survive on disk. Nothing is discarded.

An external change whose bytes equal what we last wrote is adopted silently (no alert).
The exact on-screen wording goes through the aesthetic gate in #11.
