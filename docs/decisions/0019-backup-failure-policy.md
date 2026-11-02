# 0019 — When a backup can't be written

**Status:** Accepted (2026-11-01). Refines [0005](0005-backups.md) and [0018](0018-external-change-ux.md).

| Version about to be replaced | Its backup can't be written | Result |
| --- | --- | --- |
| Someone else's (external change, "Keep My Version") | — | **Refuse.** Nothing is published; their version must never be lost. |
| Our own last save | — | **Save anyway.** The status bar says "Backups aren't working". |

## Why "save anyway" for our own versions
The new `book.json` is verified and contains the previous version plus the writer's edits. Refusing
would leave the whole session's typing only in memory, where a crash or power loss loses it. The
worst cost of saving is one lost rollback point, and the tiered snapshots and the external mirror
keep separate history.

## Also
- No external version is ever lost silently. A write that lands *during* our save (between the check and
  the final rename) is caught: where the volume supports it, an atomic swap keeps the displaced
  bytes; elsewhere the save re-checks immediately before renaming.
- Backup degradation is typed: "an older backup was lost" is distinct from "the version just replaced has no
  backup", and the store reports both.
