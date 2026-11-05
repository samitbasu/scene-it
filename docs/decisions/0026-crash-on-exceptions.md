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

So the app also arms `UnwoundTaskTrap` (`SceneIt/Diagnostics/UnwoundTaskTrap.swift`) as it launches: an observer of every
main-run-loop activity, in the common modes. If the thread says a task is current while no frame of
`libswift_Concurrency` (the job runner) is on the stack, a job was unwound, and the trap stops the app with a fixed
`fatalError` message, before the next isolation check or autosave. A run loop started inside a job, as a modal alert run from a
task does, has the job runner on its stack and is left alone. The check reads one thread-local per turn of the loop and
walks the stack only when a task is current.

Limits: the trap sees the task record, not the executor record, so an exception that unwinds an `isolated deinit` job
(which has no task) isn't caught; and an unwind caught by a run loop nested inside another job looks like that job. An
exception swallowed outside any task still carries on, as it did before, but leaves Swift concurrency intact.

Tests never raise an exception through a task: the test host would be left corrupt. They call AppKit from
`RunLoop.main.perform` (`onTheRunLoop`), so an exception there doesn't corrupt anything, and Swift Testing exit tests
are forbidden (`exit-test-guard`), because their child process launches the real app.
