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

So the app also arms `UnwoundJobTrap` (`SceneIt/Diagnostics/UnwoundJobTrap.swift`) as it launches: an observer of the main
run loop, in the common modes. If the thread says a task is current while no return address on the stack lies in
`libswift_Concurrency`'s `__TEXT` (where the job runner is), the job was left without returning through the runner, and the
trap stops the app with a fixed `fatalError` message. It does so at the next run-loop activity it observes, normally before
the next isolation check or autosave; that's not a guarantee. A run loop started inside a job, as an `NSAlert`, `NSOpenPanel`
or `NSSavePanel` run from a task does, has the job runner on its stack and is left alone.

It observes `.entry` and `.afterWaiting` only. HIToolbox's handler sits outside `CFRunLoopRunSpecific`, so after it swallows
an exception the next thing to happen on the main thread is a run-loop entry. `.afterWaiting` covers a handler inside the
loop that swallows one and lets the loop carry on; the loop can't wait and wake again without passing it. The other
activities would only repeat the check several times per turn.

Cost: per observed activity, a read of the executor record (since #142) and, when that's clear, a thread-local read plus a
retain and release of the current task (`withUnsafeCurrentTask`). Only while either record is set, which outside a job means
a modal loop run from a job, does it also take a `backtrace` into a
fixed stack buffer and compare each address against one integer range. The range is found once, from `swift_job_run`'s image
header with `getsegmentdata`. If it can't be found, the trap logs a fault once, at install, and never fires.

The trap relies on two runtime behaviours, both observed on macOS 27 with Swift 6.4, and neither of them promised:
- the job runner restores the thread's task record only by returning, so an unwind leaves it set;
- while a job runs, the runner's own frame stays on the stack below it.

Its limits:
- It reads the task record, not the executor record, so an exception that unwinds an `isolated deinit` job (which has no task)
  isn't trapped. (Lifted by the #142 amendment below.)
- An unwind caught by a run loop nested inside another job looks like that job.
- A stack deeper than the buffer (512 frames) counts as a job.
- An exception swallowed outside any task still carries on, as before, but leaves Swift concurrency intact.
- An unwound task is leaked rather than freed. That is why reading the record, with its retain and release, is safe.
- An unwound deinit job is caught only through the executor identity read from the dead frame (#142). If whatever has since
  been written there happens to be zero, the record looks clear and the trap misses it, as it did before #142. Whether that
  happens depends on the stack, so the miss is probabilistic; the next isolation check is then likely safe too, since it reads
  the same zero.

The trap is armed in the test host too. Tests that call an AppKit entry point known to raise outside its normal context (a
drag operation, an undo group) do it from `RunLoop.main.perform` (`onTheRunLoop`), so an exception there doesn't unwind a
task. The test then hangs on its continuation until the step's time limit, but Swift concurrency is left intact. Swift
Testing exit tests are forbidden (`exit-test-guard`): their child process launches the real app.

## Amendment (2026-11-08, #142): the trap reads the executor record too
Five hosted-test runs of a #102 spike crashed with `EXC_BAD_ACCESS` at `0x95a` in `FilingFlow`'s deinit, under
`swift_task_deinitOnExecutor` → `swift_task_isCurrentExecutorWithFlags` → `isMainExecutor`, while `-[NSApplication run]`
drained its autorelease pool and an `NSHostingView` released a `BookWindow`. The reports name an `HIE:` thread
(`SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`), and the spike read a layout fragment's `textElement.attributedString`
during an edit, which raises. The trap never fired.

- **Why the deinit is isolated.** With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (ADR 0011), Swift 6.4 gives every app class
  without an explicit deinit an isolated one; a `@MainActor` class in a module without the default doesn't get one. About
  50 app classes have it. Upcoming features (`InferIsolatedConformances`, `NonisolatedNonsendingByDefault`) don't matter.
- **Why the executor was garbage.** `swift_task_isCurrentExecutorWithFlagsImpl` reads the thread's executor record and asks
  whether *that* executor is the main one. The record pointed into a dead stack frame, left there by an unwound job, so its
  identity was whatever had since been written there. `FilingFlow` was only the first isolation check after the unwind.
- **Why the trap missed it.** It read only the task record. A hosted experiment that raised inside an isolated deinit, run as a
  job because its object's last reference went away off the main thread, logged no task, was swallowed by HIToolbox, and left
  the trap silent (the host then hung). The same experiment raising inside a task's job was trapped within 2 ms, even with 20
  autoreleased hosting views waiting in the pool. Which kind of job the spike unwound can't be told from the reports, but only
  the deinit job explains a silent trap.

So the trap now also reads the executor record, through the runtime's exported `swift_task_getCurrentExecutor`, found with
`dlsym` like `swift_job_run`. Swift reserves the name for `@_silgen_name`, and no Swift API reads the record without acting on
it. The function returns the runtime's `SerialExecutorRef` (identity, then witness table) in the Swift calling convention; it's
called through a C function type returning one word, which both conventions return in the same register. A non-null identity
counts as a job, as a current task does. It's read first, and costs one more thread-local read per observed activity. With
the change, the deinit experiment was trapped 1 ms after HIToolbox swallowed the exception. `anIsolatedDeinitJobIsAJob`
checks that a deinit job without a task counts as a job, not as nothing.

A third runtime behaviour, also observed rather than promised: outside any job the record is clear, so the identity is null.
The runtime ships with the OS, and its `_swift_getActiveExecutor` already falls back to the main executor on the main thread;
if a later `swift_task_getCurrentExecutor` did the same, every run-loop entry would look like an unwound job and the app would
stop at launch. So the trap calibrates itself once: `install` schedules a block on the main run loop
(`CFRunLoopPerformBlock`, outside any job) that reads the identity there. Only if it's null (`Calibration.usable`) does the
trap start reading the record; otherwise it logs a fault, as it does when the symbol is missing, and goes on reading only the
task record. Until the block runs, it reads only the task record too. `theAppArmsTheTrapOnTheMainRunLoop` checks that
calibration found the record usable, and two pure tests check the decision.

The trap was renamed from `UnwoundTaskTrap` to `UnwoundJobTrap` (and `TaskContext` to `JobContext`), since it now traps any
unwound job; the earlier sections use the new names.

Not changed: the deinits stay isolated. Making them `nonisolated` wouldn't remove the dead record; the next isolation check
(a SwiftUI update, a notification closure, `MainActor.assumeIsolated`) would read it instead. An isolated deinit also keeps
AppKit teardown on the main thread when the last reference goes away elsewhere. No source guard can spot an AppKit call that
may raise, so none was added.
