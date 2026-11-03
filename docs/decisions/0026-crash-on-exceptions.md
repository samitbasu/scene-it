# 0026 — Crash cleanly on uncaught Objective-C exceptions

**Status:** Accepted (2026-11-03)

## Decision
Set `NSApplicationCrashOnExceptions = YES` in Info.plist. An Objective-C exception that escapes into AppKit ends the app at
once, with an accurate crash report that Report a Problem (ADR 0006) picks up.

## Why
By default AppKit logs the exception and continues. While investigating #72, an exception unwinding through a Swift task left
the concurrency runtime pointing at a dead stack frame, and the eventual crash pointed somewhere unrelated. A corrupted app
could then autosave damaged data over the last good version. A clean stop loses at most the seconds since the last autosave,
and the backups (ADR 0005, 0019) cover the rest.
