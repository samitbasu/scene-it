# 0051 — Tests wait their turn before their time limit starts: `swift test` at most four at a time, hosted tests two

**Status:** Accepted (2026-11-10). Amends [0039](0039-hosted-tests-four-at-a-time.md); adds to
[0050](0050-test-host-threads-stay-free.md).

## Context
The gate now runs on GitHub's `xcode-27` macOS runner: 3 cores and 7 GB, against 8 cores on the
owner's Mac. Two failures came and went there, on code that passed on other runs.

**`swift test`: every 1-minute suite timing out together.** On main's run 42880568243, all 14
`TagEditTests` failed with "Time limit was exceeded: 60.000 seconds", and so did every test in
`StoreRaceTests` and `FiledCopyIndexesTests`. It was no deadlock: each of them finished by
itself, 133–167 s after it started, and the run ended normally after 176 s. A `TagEditTests`
test takes 0.04 s on the owner's Mac. Uncapped, Swift Testing starts all 1,157 tests at once (the
log shows 1,122 "started" with none yet finished), and a test's time limit starts with it. Every
test then shares 3 cores and the one main actor with a thousand others, so its wall time is the
whole run's: pure tests such as `intervalOrdersByDuration` took 58–90 s, on passing runs too. A
1-minute limit was a coin toss on how the queue fell.

A probe package (Swift Testing 2403, Xcode 27.2, run under `swift test` as the gate runs the
core tests, on the owner's Mac) showed what a cap changes. With
`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=2`, a `.timeLimit(.minutes(1))` test queued 69 s
behind two 65 s tests passed: a test takes its slot before its time limit starts. (Its "passed
after 70 s" in the log still counts the wait: the "started" event comes before the slot.)

**Hosted: `PageFuzzTests` past its 2-minute limit.** The page fuzz waits for 400 main-thread
turns. At width 4, each turn waits for three other tests' work on the main thread, and on the
runner that work is about four times slower than on the owner's Mac. A seed took 43–104 s on
passing runs and over 120 s on PR #196's first attempt. It wasn't `swift test` competing for the
cores: with `swift test` finished before the hosted tests started, the seeds still took 71 and
86 s.

## Decision
- `check.sh` runs `swift test` with `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`, so a
  core test's time limit measures the test, not the queue in front of it. `just test` and a
  filtered run are unchanged.
- The scheme's hosted width goes from 4 to 2 (`ParallelismTests` now expects 1 or 2).
- Both test targets check that the toolchain honors the width they run with:
  `theToolchainHonorsTheParallelizationWidth` (core, only when the variable is set) and
  `theToolchainHonorsTheSchemesParallelizationWidth` (hosted). Eight cases of one test each
  hold a place for 200 ms and expect no more than the width of them at once. Uncapped, the
  cases start together and all eight overlap; load only spreads them out, so it can't fail
  them.

Measured on the runner (one run each, `swift test` and the hosted tests at once, as the gate
runs them):

| `swift test` width | Hosted width | `swift test` run | Time-limit failures | Hosted run | Page fuzz seeds |
| --- | --- | --- | --- | --- | --- |
| default | 4 | 146–176 s | 0–49 | 393–404 s | 43–104 s, one over 120 s |
| 4 | 4 | 177 s | 0 | 385 s | 49 s, over 120 s |
| **4** | **2** | **198 s** | **0** | **448 s** | **12 s, 17 s** |

The bold row is one run, before the guards; the PR's head then passed five more gate runs. The
hosted run takes about a minute longer on the runner; the page fuzz runs six times faster.

On the owner's Mac the gate no longer runs, but Xcode's ⌘U and `just test-app` take the
scheme's width too: 0039 measured the hosted run at 106 s at width 2 against 88 s at width 4.

## Alternatives
- **Raise the time limits.** They would have to track the size of the suite and the speed of the
  runner, and a hang would take longer to report.
- **Run `swift test` before the hosted tests.** Measured: it doesn't help the fuzz (above), and
  the gate takes longer.
- **Cap `swift test` at the core count.** No measured gain over 4.

## Risk
As in 0039, the variable is experimental. If a toolchain drops it, the probes above fail: all
eight cases run at once. If `check.sh` stops setting it, the core probe is skipped instead, and
the old failures return; a pure core test taking over a minute in `swift-test.log` is the sign.

## Learning notes
Swift Testing's `.timeLimit` is like wrapping each test in `tokio::time::timeout`: if a thousand
futures are spawned at once on a three-thread runtime, each one's timeout is mostly spent
waiting to be polled. Capping the width is like a `Semaphore` acquired before the timeout
starts.
