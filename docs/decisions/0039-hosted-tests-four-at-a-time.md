# 0039 — The hosted tests run at most four at a time

**Status:** Accepted (2026-11-07), resolves #132. Amended by
[0051](0051-tests-wait-their-turn-before-their-time-limit.md): the width is now 2.

## Decision
The scheme's test action sets `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH = 4`, so Swift
Testing runs at most four app-hosted tests at once. The test action no longer takes the
launch action's environment (it had none). `ParallelismTests` checks that the host sees the
setting. The `SceneItCore` package tests (`swift test`) are unchanged.

## Why
Every hosted test runs on the one main thread. Running more of them at once adds no
throughput. It interleaves them, so each test's time stretches to cover everyone else's
work too. A sample of the host during the gate showed the main thread fully busy, with about
two thirds of it spent laying out new test windows (SwiftUI and toolbar layout). The fuzz
tests wait for hundreds of run-loop turns, so they finished last. Their first seed took about
as long as the whole hosted run (75–90 s), against a two-minute limit. The second seed, run
after the rest had finished, took 3–10 s.

Measured on the hosted suite (`test-without-building`, 285 tests, idle machine):

| Width | Hosted run | Slowest test case |
| --- | --- | --- |
| default | 95 s | 90 s (`PageFuzzTests`, seed 1) |
| 8 | 86 s | 58 s |
| **4** | **88 s** | **11 s** |
| 2 | 106 s | 7 s |
| 1 (serial) | 163 s | 7 s |

At width 4 the run takes no longer than before, and no test case takes more than about 15 s in the gate.
That held with eight busy-loop processes running alongside (load average 24): 90 s for the
run, 9 s for the slowest case. Some parallelism is still worth having, because tests also
wait on disk, timers and background search.

## Alternatives
- **Fewer run-loop turns per fuzz step.** This saves at most a quarter to a half of the turns.
  Each turn still waits for the other tests' work, so the time would still grow with the suite.
- **Split the seeds, or raise the limit.** The seeds are already timed separately. A larger
  limit would just track the suite's size.
- **`-parallel-testing-enabled NO`, or width 1.** Each test is fast, but the run takes 70% longer.

## Risk
The variable is experimental in Swift Testing. If a toolchain drops it, the cap goes silently
and the old timings return. `ParallelismTests` catches the setting being removed from the
scheme, but not the toolchain ignoring it. A gate time near 90 s on a fuzz case is the sign.
The cap lives in the scheme's test action under this exact name. An explicit `.xctestplan`,
or a toolchain that renames the variable, must carry it, or the cap is lost the same way.

## Learning notes
Swift Testing runs tests concurrently by default, as `cargo test` does with threads. But a
`@MainActor` test is like a future pinned to a single-threaded executor. Many of them at once
share that one thread, so a long run of synchronous work in one test (a window's first
layout) delays every other test's next `await`. Swift Testing's `.timeLimit` counts wall-clock
time per test case, including the time spent waiting for other tests.
