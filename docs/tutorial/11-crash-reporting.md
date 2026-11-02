# 11 — Logging, crash detection and problem reports

How Scene It notices that it crashed, what it keeps on disk to explain why, and how a
writer sends that to us without any of their book in it ([ADR 0006](../decisions/0006-crash-reporting.md),
[ADR 0009](../decisions/0009-report-destination.md)).

| Piece | Where | Rust analogue |
| --- | --- | --- |
| `Log` facade over `os.Logger` | [`Sources/SceneItCore/Diagnostics/Log.swift`](../../Sources/SceneItCore/Diagnostics/Log.swift), [`LogValue.swift`](../../Sources/SceneItCore/Diagnostics/LogValue.swift) | `tracing` macros with a restricted field type |
| `LogRing`, our own on-disk copy | [`Sources/SceneItCore/Diagnostics/LogRing.swift`](../../Sources/SceneItCore/Diagnostics/LogRing.swift) | a `tracing-appender` rolling file writer, size-capped |
| Session marker | [`Sources/SceneItCore/Diagnostics/SessionMarker.swift`](../../Sources/SceneItCore/Diagnostics/SessionMarker.swift) | a PID/lock file checked at startup |
| MetricKit subscriber | [`SceneIt/Diagnostics/MetricKitSubscriber.swift`](../../SceneIt/Diagnostics/MetricKitSubscriber.swift), [`PayloadArchive.swift`](../../Sources/SceneItCore/Diagnostics/PayloadArchive.swift) | none: the OS hands you last run's backtraces |
| `ProblemReport` builder | [`Sources/SceneItCore/Diagnostics/ProblemReport.swift`](../../Sources/SceneItCore/Diagnostics/ProblemReport.swift) | a `zip` of logs, built by your own code |
| UI: alert, Help menu, report window | [`SceneIt/Diagnostics/`](../../SceneIt/Diagnostics/) | none |
| Every on-screen string | [`Sources/SceneItCore/Diagnostics/ReportWording.swift`](../../Sources/SceneItCore/Diagnostics/ReportWording.swift) | one `strings.rs` |

Everything lives in `~/Library/Application Support/Scene It/Diagnostics/`:

```
session.marker            present while the app runs
Log/log.jsonl             LogRing: current file
Log/log.1.jsonl           LogRing: previous file
MetricKit/diagnostic-….json
```

## `os_log` versus `tracing`

`os.Logger` writes to the **unified logging system**. You don't own the sink: the
`logd` daemon collects every process's messages into a compressed, system-wide store, and
you read it with Console.app or the `log` tool:

```sh
log stream --level info --predicate 'subsystem == "com.samitbasu.SceneIt"'
log show --last 1h --info --predicate 'subsystem == "com.samitbasu.SceneIt"'
```

| `tracing` | `os.Logger` |
| --- | --- |
| target (`my_crate::store`) | subsystem + category (`com.samitbasu.SceneIt` / `store`) |
| `trace!` `debug!` `info!` `warn!` `error!` | `.debug` `.info` `.notice` `.error` `.fault` |
| subscriber decides what's kept | the OS decides: by default `.debug` and `.info` live only in a memory buffer, while `.notice`, `.error` and `.fault` are written to disk |
| formatting happens at the call | formatting is deferred: the binary stores a format string and the raw arguments |

That last row is why `Logger`'s messages are an `OSLogMessage` built from string
interpolation, not a `String`. The compiler turns `"saved \(count) scenes"` into a static
format plus arguments.

### Privacy redaction

Each interpolated value in an `OSLogMessage` carries a privacy level. Dynamic strings and
objects default to `.private`. On a normal Mac they're stored as `<private>`, unless a
configuration profile turns private data on. Numbers default to public. You choose explicitly
with `"\(name, privacy: .public)"` or `.private(mask: .hash)`.

That protects writers in the system log, but it isn't enough for us:

1. We **copy** our messages to our own file (below) and into problem reports, and that copy
   has no redaction.
2. A privacy annotation is a convention someone has to remember at every call site.

So `Log` makes the rule part of the type system:

```swift
// PayloadArchive.swift
Log.diagnostics.info("Saved MetricKit payload", ["size": .bytes(Int64(json.count))])
```

- The message is a `StaticString`, which is a literal in our source code. You can't build one
  at run time, so passing a scene's text as the message doesn't compile.
- Metadata values are `LogValue`: `.count`, `.bytes`, `.interval`, `.id(UUID)`,
  `.symbol(StaticString)` and `.error(LoggedError)`. No case holds a runtime `String`.
- `LoggedError` keeps an error's type, domain and code but **not** its description, because
  descriptions often quote a file name or the text being processed.

Since everything that reaches the log was written by us, `Log` emits it with
`privacy: .public`. In Rust terms, it's like a logging macro that only accepts
`&'static str` messages and fields whose types implement a sealed `SafeValue` trait.

## `OSLogStore` and the `LogRing`

`OSLogStore` reads the unified log back. On macOS, an app without special entitlements
can only open `OSLogStore(scope: .currentProcessIdentifier)`. That means **this run only**,
but a report after a crash needs the run that crashed. So `Log` also appends every
`.info`-and-above entry to a `LogRing`:

- JSON lines, one entry per line, in `log.jsonl`. When it would grow past half the cap
  (1 MiB total by default), it replaces `log.1.jsonl` and a new `log.jsonl` starts. Disk use
  stays bounded and the newest entries survive.
- A crash can cut the last line in half. The reader skips any line that doesn't decode.
- Writes take a `Mutex` (from the `Synchronization` module, like `std::sync::Mutex`) because
  `Log` is called from any thread.

A report includes both: `logs/recent-sessions.log` (the ring, across launches) and
`logs/this-session.log` (`OSLogStore`, filtered to our subsystem). Other frameworks'
messages in our process are left out, because their privacy annotations aren't ours to vouch for.

## Detecting a crash: the marker file

A process can't reliably report its own crash. By the time a signal handler runs, the heap
may be corrupt, and Swift's `fatalError` traps directly. So we check on the way back in:

1. At launch (`applicationWillFinishLaunching`), read `session.marker`, then write a new one
   with this launch's time.
2. On a clean quit (`applicationWillTerminate`), delete it.
3. If a marker is already there at launch, the previous run never reached step 2.

The decision is a pure function, `MarkerObservation.lastSession`:

| On disk at launch | Result |
| --- | --- |
| no marker | `.cleanLastTime` |
| marker with a launch time | `.crashedLastTime(lastLaunch: time)` |
| marker we can't decode | `.crashedLastTime(lastLaunch: file's modification time)` |

False positives are possible: Force Quit, a power cut, or **stopping the app in Xcode**
all skip step 2, and the next launch offers a report. That's fine. Missing a real crash
would be worse.

App-hosted tests launch the real app. Under the test runner (`XCTestConfigurationFilePath`
is set) diagnostics go to a fresh temporary folder, so a test run never leaves a marker in
your real Application Support.

## MetricKit

`MXMetricManager` delivers **diagnostic payloads** (crashes, hangs, CPU and disk-write
exceptions, each with a backtrace) to any registered `MXMetricManagerSubscriber`, on a
later launch, when the system chooses. `MetricKitSubscriber` saves each payload's
`jsonRepresentation()` into `MetricKit/` and prunes:

- `RetentionPolicy.expired(_:now:)` is a pure function: anything older than 30 days goes,
  then everything beyond the newest 20. It's tested without touching the disk.
- The subscriber is `nonisolated` because MetricKit calls it on a background queue, and the
  app target is main-actor by default ([ADR 0011](../decisions/0011-mainactor-default-isolation.md)).

## `.ips` crash reports

When any app crashes, macOS's ReportCrash writes `~/Library/Logs/DiagnosticReports/<Process>-<date>.ips`.
After the report has been sent to Apple, it may move to the `Retired/` subfolder. The format is
two JSON documents: a one-line header (`app_name`, `app_version`, `slice_uuid`,
`incident_id`), then the body with `exception`, `asi` (the `fatalError` message,
if any), `faultingThread`, `threads` (frames as `imageIndex` + `imageOffset`) and
`usedImages` (each binary's load address `base` and `uuid`).

A report includes the newest 10 `.ips` files whose names start with `Scene It`, from both folders.

## Building the report

`ProblemReport.build(_:in:)` takes everything as `Inputs`: the log sources, the MetricKit
folder, the DiagnosticReports folder, a `SystemSummary` and a `StatusSummary` (settings and
backup state; its values are `LogValue`s, so it can't carry book text either). It's
**best-effort**. Each piece is gathered on its own, and a failure is recorded under
"Not included" in `manifest.txt` and skipped. Only a failure to create the report folder throws.

The folder is zipped with `NSFileCoordinator` and the `.forUploading` reading option. Asked to
read a directory "for uploading", the coordinator hands you a temporary zip of it. That's
in-process, uses no third-party code and no subprocess, and keeps working if we ever
sandbox. If zipping fails anyway, the report is the unzipped folder.

The test `reportContainsNoManuscriptText` builds a report from fixtures that put a fixture
book's sentences where a careless implementation would pick them up (another app's crash
report, an error's description). It then unzips the result and checks that no file contains them.

## Reading a report you receive

1. Unzip. Read `manifest.txt` first: it lists every file and what couldn't be gathered.
2. `system.txt`: app version and build, macOS version, Mac model.
3. `logs/recent-sessions.log`: our own log across launches, with UTC timestamps. A
   `Launched lastSession=crashed` line marks the start of the session after a crash, and the
   lines just above it are the last things the crashed session did.
4. `crash-reports/*.ips`: double-click to open in Console, or read the JSON. Start at
   `exception`, `asi` and the `faultingThread`'s frames.
5. `metrickit/*.json`: the same crash, as MetricKit saw it, sometimes with hang or
   resource-exception reports the `.ips` files don't have.

### Symbolication

Debug builds keep their symbols, so `.ips` frames show function names. **Release builds
are stripped.** Their frames are just addresses, and you need the build's **dSYM**
(the DWARF debug info, like a separate `.debug` file from `objcopy --only-keep-debug`).
`scripts/release.sh` (#4) must archive the dSYM of every release it ships. Without it,
crashes from that release can't be symbolicated.

To symbolicate one frame:

```sh
# Find the dSYM whose UUID matches the crashing binary's `uuid` in `usedImages`.
mdfind "com_apple_xcode_dsym_uuids == <UUID>"
dwarfdump --uuid "Scene It.app.dSYM"

# address = image base + imageOffset (both from the .ips)
atos -arch arm64 -o "Scene It.app.dSYM/Contents/Resources/DWARF/Scene It" \
     -l <base> <address>
```

`atos` is roughly `addr2line`. Console.app symbolicates automatically when Spotlight can
find the matching dSYM, for example inside an `.xcarchive` in `~/Library/Developer/Xcode/Archives`.

## Trying it

In a Debug build there is a **Debug** menu with **Crash Now**, which calls `fatalError`.
It's compiled out of Release (`#if DEBUG`). Choose it, relaunch, and the
"quit unexpectedly" alert appears. Choose **Send Report…** to see the report window.
