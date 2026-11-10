# 0050 — Tests never use up a thread pool: no window animations in the test host, a cap on held gates

**Status:** Accepted (2026-11-09), resolves #167 and #178. Adds to [0039](0039-hosted-tests-four-at-a-time.md).

## Context
Gates failed under load with time limits that had nothing to do with the change being gated: a web view
test's 1-minute limit, a comment test's 2-minute limit, the formatting fuzz, dozens of core store tests
at 60 s, and four Diagnostics tests "crashed with signal kill" at 0.000 s. Two pools were running dry.

**The test host's dispatch threads.** Ordering a window in or closing it starts AppKit's window transform
animation (`_NSWindowTransformAnimation`), which runs blocking on a dispatch worker thread. For the test
host's offscreen windows it never finishes, so every test window kept one or two worker threads for good.
A process gets 64 of them (`kern.wq_max_constrained_threads`). A sample of the host 60 s into a hosted
run showed 65 threads parked in `-[NSAnimation _runBlocking]`. From then on, anything queued on a global
queue never ran (a `WKWebView` load, for one), so its test waited until its suite's `.timeLimit`. The gate
doesn't pass `-test-timeouts-enabled`, but Xcode reports a Swift Testing time limit in XCTest's words
("Test exceeded execution time allowance of 1 minute"), and it then ends that host: the rest of the run
went on in a host with a new process ID. In a probe, a test that was running beside the one that ran out
of time never appeared in the results; in the gate, four such tests were reported as "crashed with signal
kill" at 0.000 s. A run of 40 page tests beside the web view test reproduced the time-out at a load
average of 3.

**Swift's shared async pool in `swift test`.** `Gate` holds a fake file-system call until the test opens
it. The store makes those calls synchronously on a thread of Swift's cooperative pool, which has one
thread per core (8). With 8 gated tests running at once, every pool thread waited in `Gate.pass()`, and
nothing that would open a gate could run (a `Task.sleep` wakes on the pool), so the run hung until the
gate step's 15-minute kill, or, once Swift Testing's limits fired, failed every store test at 60 s.

## Decision
- The scheme's test action passes `-NSAutomaticWindowAnimationsEnabled NO`. It goes to the test host's
  argument domain only: nothing is written to the app's defaults, and the app run normally keeps its
  animations. `theSchemeTurnsWindowAnimationsOffInTheTestHost` fails if it's removed.
- A gate exists only inside `withGate { gate in … }`, which first takes one of `GatePermits` (half the
  pool's threads), waiting for it as an async suspension, never on a pool thread. However the body ends,
  `withGate` opens the gate and returns the permit. A held gate still blocks its thread: the store's
  `FileSystem` is synchronous, so the fake can't suspend inside it. The cap keeps the other half of the
  pool free. On a one-core host the pool is a single thread, which any held call takes, so the gated
  tests need two cores or more. `moreHeldSavesThanThePoolHasThreadsAllFinish` holds more saves than
  there are cores; uncapped, it hangs.
- Waits on the store wait for the event itself: `whenObserved` checks an `@Observable` condition again
  each time something it read changes, and `Gate.waitForArrival` awaits the arrival. Neither has a budget
  that load can use up. Both, and the wait for a permit, end when the task is cancelled, recording an
  issue, so a suite's time limit turns a real hang into a failure at the limit (checked by hand: a
  condition that never holds under a 1-minute limit failed after 64 s). `CancelledWaitTests` covers the
  cancellation itself.
- `eventually` (a poll budget) stays where the condition isn't observable: AppKit's run loop in the
  hosted tests, and a few core tests that wait on a plain class or a `ManualClock`'s sleepers
  (`FileACopyTests` on `queued.result`, `AutosaveDriverTests`, `SceneCardsTests`).

## Alternatives
- **Raise the time limits.** The hangs were real hangs: nothing would have finished.
- **Set `animationBehavior = .none` on each test window.** That misses windows the app makes in the
  integration tests, and every new test window would have to remember it.
- **Run the store's file system calls on an executor of their own.** That changes the app for the sake
  of a fake, and the real disk calls don't wait on a test.

## Learning notes
Swift's cooperative pool is like a Tokio runtime with one worker per core: a blocking call parks a worker,
and enough of them park the runtime. `spawn_blocking` has no direct equivalent; here the blocking callers
are capped instead. GCD's worker pool is separate and larger, but it is finite too, and AppKit can leak
from it.
