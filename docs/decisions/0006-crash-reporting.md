# 0006 — Built-in "Report a Problem"

**Status:** Accepted (2026-11-01)

## Decision
Use Apple frameworks only:
- **`os.Logger`** with subsystem `com.samitbasu.SceneIt` and one category per area (store, backup, editor…). It's structured and cheap. Never log manuscript text, and mark dynamic values `.private` unless they're harmless.
- **Crash detection:** a "session running" marker file is written at launch and removed on clean quit. If it's still there at the next launch, the previous run crashed.
- **MetricKit** (`MXMetricManager`) receives crash and hang diagnostics on later launches. They're saved to Application Support.
- **Help → Report a Problem…** (offered automatically after a detected crash) builds a zip containing recent logs (via `OSLogStore`), MetricKit payloads, matching `.ips` files from `~/Library/Logs/DiagnosticReports`, the app and OS version, and a summary of settings. No manuscript text is included. The writer previews what's in the zip, and the app opens a prefilled email with the zip revealed in Finder to attach.

The destination address is a pending decision (GitHub issue labelled `decision`).

## Rust analogy
`os.Logger` ≈ `tracing` with a system-wide collector. A crash `.ips` ≈ a
symbolicated backtrace that the OS writes for you. MetricKit is the OS handing
you the backtraces from crashes in your previous runs.
