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

## Amendment (2026-11-05, #120): the key doesn't cover the run loop; a trap does
`NSApplicationCrashOnExceptions` is read only by AppKit's own handlers around event dispatch. An exception that escapes
anything the run loop calls (a Swift task's job, a timer, an observer, a `RunLoop.perform` block) unwinds to HIToolbox's
handler in `RunCurrentEventLoopInMode`. That handler logs an `HIExceptions` fault, leaves a thread named `HIE: …` and
`SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION` in the next crash report, and carries on, whatever the key says.

#120 was the #72 failure again. A test called `NSTextView.performDragOperation(_:)` directly from an async test body, NSUndoManager
raised, HIToolbox swallowed it, and about 100 ms later `UndoRouter`'s notification closure crashed in
`swift_task_isMainExecutor`, reading the dead frame the job runner had left as the thread's current executor. The router was
just the first code to make an isolation check.

So the app also arms `UnwoundTaskTrap` (`SceneIt/Diagnostics/UnwoundTaskTrap.swift`) as it launches: an observer of the main
run loop, in the common modes. If the thread says a task is current while no return address on the stack lies in
`libswift_Concurrency`'s `__TEXT` (where the job runner is), the job was left without returning through the runner, and the
trap stops the app with a fixed `fatalError` message. It does so at the next run-loop activity it observes, normally before
the next isolation check or autosave; that's not a guarantee. A run loop started inside a job, as an `NSAlert`, `NSOpenPanel`
or `NSSavePanel` run from a task does, has the job runner on its stack and is left alone.

It observes `.entry` and `.afterWaiting` only. HIToolbox's handler sits outside `CFRunLoopRunSpecific`, so after it swallows
an exception the next thing to happen on the main thread is a run-loop entry. `.afterWaiting` covers a handler inside the
loop that swallows one and lets the loop carry on; the loop can't wait and wake again without passing it. The other
activities would only repeat the check several times per turn.

Cost: per observed activity, one thread-local read plus a retain and release of the current task (`withUnsafeCurrentTask`).
Only while a task is current, which outside a job means a modal loop run from a task, does it also take a `backtrace` into a
fixed stack buffer and compare each address against one integer range. The range is found once, from `swift_job_run`'s image
header with `getsegmentdata`. If it can't be found, the trap logs a fault once, at install, and never fires.

The trap relies on two runtime behaviours, both observed on macOS 27 with Swift 6.4, and neither of them promised:
- the job runner restores the thread's task record only by returning, so an unwind leaves it set;
- while a job runs, the runner's own frame stays on the stack below it.

Its limits:
- It reads the task record, not the executor record, so an exception that unwinds an `isolated deinit` job (which has no task)
  isn't trapped.
- An unwind caught by a run loop nested inside another job looks like that job.
- A stack deeper than the buffer (512 frames) counts as a job.
- An exception swallowed outside any task still carries on, as before, but leaves Swift concurrency intact.
- An unwound task is leaked rather than freed. That is why reading the record, with its retain and release, is safe.

The trap is armed in the test host too. Tests that call an AppKit entry point known to raise outside its normal context (a
drag operation, an undo group) do it from `RunLoop.main.perform` (`onTheRunLoop`), so an exception there doesn't unwind a
task. The test then hangs on its continuation until the step's time limit, but Swift concurrency is left intact. Swift
Testing exit tests are forbidden (`exit-test-guard`): their child process launches the real app.
