# 0005 — Backups: rotation, tiered snapshots, external mirror

**Status:** Accepted (2026-11-01). **Extends PLAN §5.4.**

## Problem
PLAN rotates `book.json.bak1…bak3` on *every* save. With a 2 s autosave, all
three backups can be seconds old, so they protect against a corrupt write but not
against "I deleted a chapter an hour ago".

## Decision
Three layers, all written only after the new `book.json` has been encoded and verified:
1. **Rotation (PLAN):** `bak1…bak3` protect against a bad write.
2. **Tiered snapshots** in `<book>.sceneit/Backups/`: keep at most one per 10 minutes for the last 24 h, one per day for 30 days, then one per week. Pruning is a pure function `(snapshots, now) -> toDelete`, unit-tested exhaustively.
3. **External mirror:** the newest snapshot is also copied to `~/Library/Application Support/Scene It/Backups/<book-uuid>/`, with the same tiering. This survives deletion or corruption of the whole package, for example by a sync service. The book's UUID is stored in the package's `Backups/book-id` file, so `book.json` stays exactly as specified in PLAN §5.2.

A backup failure never blocks a save of `book.json`. It is logged and shown in the status bar.

## Not chosen (for now)
A restore UI and a lock against a second writer. Recovery is by hand
("Show Package Contents"); see `docs/user/recovery.md` (to be written).
