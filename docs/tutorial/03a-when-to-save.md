# 03a — When to save

Chapter 03 covered *how* a book gets onto disk. This one covers *when*: the autosave
scheduler (PLAN §5.4, issue #10). It's a small piece of code that teaches four things a
Rust programmer meets early in Swift: modelling a scheduler as a pure state machine, the
`Clock` protocol, task cancellation, and `@MainActor`.

## Where the code is

Everything lives in [`Sources/SceneItCore/Autosave/`](../../Sources/SceneItCore/Autosave/):

| File | What it holds |
| --- | --- |
| [`AutosaveScheduler.swift`](../../Sources/SceneItCore/Autosave/AutosaveScheduler.swift) | the pure state machine: events in, a decision out; `AutosavePolicy`'s timings |
| [`AutosaveDriver.swift`](../../Sources/SceneItCore/Autosave/AutosaveDriver.swift) | runs the machine on the main actor with one timer task and a weakly held `AutosaveSaver` |
| [`QuitDecision.swift`](../../Sources/SceneItCore/Autosave/QuitDecision.swift) | what quitting does, as a function of the autosave state |
| [`QuitWording.swift`](../../Sources/SceneItCore/Autosave/QuitWording.swift) | the alert shown when quitting would lose edits |

The tests are in [`Tests/SceneItCoreTests/Autosave/`](../../Tests/SceneItCoreTests/Autosave/), with
a hand-advanced test clock in [`ManualClock.swift`](../../Tests/SceneItCoreTests/Autosave/ManualClock.swift).

## The rules

- Save 2 s after the last edit, and at least every 30 s while editing continues (measured from
  the first unsaved edit).
- Save at once on a scene switch, when the app is deactivated, on quit and on Cmd+S.
- Never start a save while one is running. Edits made during a save are saved by the next one.
- After a failure, retry after 2 s, 5 s, 15 s, then every 30 s, for as long as edits are unsaved.
- If another program changed the book, pause until the writer decides what to keep
  ([ADR 0018](../decisions/0018-external-change-ux.md)). After "Keep My Version", saves may
  replace the other program's version (keeping it as a backup) until one succeeds.
- Never lose edits on quit without asking.

---

## 1. A scheduler as a pure state machine

The tempting design is a class with a timer, an `isSaving` flag, a `pendingEdits` flag, a
`lastError` and a `paused` flag, each updated from a different callback. Five flags make 32
combinations, and most of them are nonsense ("paused and saving", "clean but with an error").
Tests have to wait for real timers to fire.

Instead the scheduler is a value type with one transition function. It never reads a clock and
never sleeps: every input is an event *at an instant*, and the output says what the caller must
do next.

```swift
public mutating func handle(_ event: AutosaveEvent, at now: Instant) -> Decision
```

```swift
public enum Decision: Hashable, Sendable {
    case idle
    case waitUntil(Instant)
    case saveNow(SaveRequest)
}
```

A `SaveRequest` carries the `SaveTrigger` (why) and the `ExternalChangePolicy` the save must
pass to `BookPackage.save`.

The state is **one enum**, so the illegal combinations can't be written down
(CLAUDE.md, "illegal states should be unrepresentable"):

```swift
public enum State: Hashable, Sendable {
    case clean
    /// There are unsaved edits and no save is running.
    case unsaved(Unsaved)
    case saving(Saving)
    /// A save found that another program changed the book. Nothing is saved until the
    /// writer resolves it (ADR 0018) and `externalChangeResolved` arrives.
    case paused(Paused)
}
```

Each case carries only what makes sense in it. `Saving` remembers which edits the running
save covers and which arrived since; `Unsaved` may carry the last `Failure`, which is what the
status bar shows and what the retry backoff counts. There's no `isSaving` to forget to reset:
a save is running exactly when the state is `.saving`.

The writer's "Keep My Version" lives in the state too, as `onExternalChange` on `Unsaved` and
`Saving`, rather than in a flag on the store. `externalChangeResolved` sets it while leaving
`.paused`. It survives ordinary failures (the retry still needs it), and a successful save or a
new pause clears it. Outside `.paused`, the event does nothing, so there's no way to approve an
overwrite the writer was never asked about.

`.saveNow` isn't advice. When `handle` returns it, the state has already moved to
`.saving`, so the driver can't start a save and forget to say so. The only thing the driver
must do is report `saveSucceeded` or `saveFailed` when the save ends.

### Swift and Rust side by side

In Rust you'd write the same thing as a `match` over `(state, event)`:

```rust
fn next(state: State, event: Event, now: Instant) -> State {
    match (state, event) {
        (_, Event::Tick) => state,
        (State::Clean, Event::Edited) => State::Unsaved(Unsaved::new(now)),
        (State::Saving(s), Event::SaveSucceeded) => match s.edits_since { … },
        …
    }
}
```

Swift's `switch` matches tuples of enums too, and is just as exhaustive:

```swift
switch (state, event) {
case (_, .tick):
    return state

case (.clean, .edited):
    return .unsaved(Unsaved(edits: Edits(at: now), failure: nil, requested: nil))
case (.clean, _):
    return .clean
…
```

Two differences matter here.

- **`var` bindings in patterns.** `case (.unsaved(var unsaved), .edited):` binds a mutable copy
  of the payload. You change the copy and wrap it back up (`return .unsaved(unsaved)`). Rust
  would bind `mut unsaved` by value the same way, since the `match` consumes `state`.
- **Generics over the instant type.** `AutosaveScheduler<Instant: InstantProtocol<Duration>>`
  is generic over the clock's instant, the way a Rust scheduler might be generic over
  `I: Ord + Add<Duration>`. Production uses `ContinuousClock.Instant`; tests use a
  `ManualClock.Instant` that is just an offset from zero. `InstantProtocol<Duration>` is a
  *primary associated type* constraint: it reads like Rust's `Iterator<Item = u8>`.

  A generic Swift type can't have `static let` stored properties ("static stored properties
  not supported in generic types"), which is why the timings live in a separate non-generic
  `AutosavePolicy` enum.

### Testing without sleeping

Because the machine is pure, a test is a list of events and expected decisions:

```swift
@Test func savesTwoSecondsAfterTheLastEdit() {
    var scheduler = Scheduler()
    #expect(scheduler.handle(.edited, at: at(.zero)) == .waitUntil(at(.seconds(2))))
    #expect(scheduler.handle(.tick, at: at(.milliseconds(1999))) == .waitUntil(at(.seconds(2))))
    #expect(scheduler.handle(.tick, at: at(.seconds(2))) == .saveNow(.typingPaused))
    #expect(scheduler.isSaving)
}
```

[`AutosavePropertyTests.swift`](../../Tests/SceneItCoreTests/Autosave/AutosavePropertyTests.swift)
plays hundreds of random event streams through the machine the way the driver would (ticking
at each deadline, one save at a time) and checks after every step that `.clean` means every
edit was saved, and that unsaved edits always have a pending save, a failure being retried, or
a pause. It then stops editing and checks that everything reaches disk.

## 2. The `Clock` protocol

Swift's standard library has a `Clock` protocol, roughly:

```swift
protocol Clock<Duration>: Sendable {
    associatedtype Instant: InstantProtocol
    var now: Instant { get }
    var minimumResolution: Duration { get }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws
}
```

`ContinuousClock` (keeps counting while the Mac sleeps) and `SuspendingClock` (doesn't) are the
two built-in ones. Rust's standard library has `Instant` but no clock trait, so crates such as
`tokio` grow their own (`tokio::time::pause`). In Swift the abstraction is standard, and
`AutosaveDriver<C: Clock<Duration>>` takes any clock.

The test clock, `ManualClock`, only moves when a test calls `advance(by:)`. Its
`sleep(until:)` parks a continuation in a dictionary; `advance` resumes every sleeper whose
deadline has passed. A sleep whose deadline has *already* passed returns immediately, so it
doesn't matter whether a test advances the clock before or after the driver's timer task has
started sleeping.

## 3. Task cancellation

The driver keeps one timer task, sleeping until the scheduler's deadline:

```swift
let task = Task { [weak self, clock] in
    do {
        try await clock.sleep(until: deadline, tolerance: nil)
    } catch {
        return
    }
    guard !Task.isCancelled, let self else { return }
    self.timer = nil
    self.send(.tick)
}
```

Cancellation in Swift is **cooperative**, much like dropping a future in Rust, with one
difference: dropping a Rust future stops it at its current `.await` and it never runs again,
but `task.cancel()` only sets a flag. The task keeps running until something checks the flag.
Clocks' `sleep` does check it, and throws `CancellationError` (that's the `catch { return }`).

The `guard !Task.isCancelled` after the sleep isn't redundant. The sleep can finish just
before `cancel()` is called, while the task is still waiting for its turn on the main actor. By
the time it runs, the driver may have replaced this timer with a new one, so it checks the flag
again before touching `self.timer`.

Most keystrokes don't cancel anything. Each edit moves the idle deadline later, and an earlier
timer is kept: when it fires, `tick` re-derives the later deadline and a new timer is started.
A tick is always harmless, because the decision comes from the state, not from the timer.

## 4. `@MainActor`

`AutosaveDriver` is `@MainActor`
([ADR 0011](../decisions/0011-mainactor-default-isolation.md); `SceneItCore` has no default
isolation, so it says so explicitly). That buys three things:

- **The state machine needs no lock.** Every event, from the editor, the timer or a finished
  save, is handled on the main actor, one at a time.
- **Tasks inherit it.** A `Task { … }` created in a `@MainActor` method runs its body on the
  main actor, so the timer task can call `self.send(.tick)` without an `await`.
- **The saver is main-actor too.** It's a protocol, held weakly:

  ```swift
  @MainActor
  public protocol AutosaveSaver: AnyObject {
      func save(_ request: SaveRequest) async throws(SaveError)
  }
  ```

  The store owns its driver and is also its saver. A closure that captured the store would
  make a cycle (store → driver → closure → store), and ARC never frees a cycle (chapter 00
  §7.1). A `weak` reference to a protocol is the Swift version of Rust's `Weak<dyn Trait>`, and
  it's why the protocol must be `AnyObject` (class-only): only class instances can be
  referenced weakly.

- **The save starts in the same turn as `.saveNow`.** The driver runs it with
  `Task.immediate` (new in macOS 26), which runs the task body synchronously on the current
  actor until its first suspension. A plain `Task { … }` would only be *enqueued*, so another
  event (another keystroke) could slip in before the save looked at the book. With
  `Task.immediate`, the saver's code before its first `await` (taking the snapshot) runs before
  `send` returns, so a save covers exactly the edits the scheduler thinks it covers. Edits after
  that arrive as `.edited` and are saved next. This is chapter 00 §8.4's reentrancy rule turned
  into a protocol: capture before you `await`.

  There's a consequence: a saver that finishes without suspending (one that throws at once,
  for example) reports its outcome *inside* `send`, which re-enters `send`. That's safe because
  `send` finishes changing the state before it starts the save, and does nothing with the
  state afterwards. A test covers it.

  For the same reason, the store must send `.edited` in the same main-actor turn as the
  change to the model.

The driver is also `@Observable`, so the status bar can read `driver.state` and redraw when it
changes.

## 5. Quitting

`applicationShouldTerminate` must answer synchronously, but saving is asynchronous. AppKit's
answer is `.terminateLater`, followed later by `NSApp.reply(toApplicationShouldTerminate:)`.

The decision itself is pure, a computed property on the scheduler's state:

| State after `quitRequested` | `quitDecision` |
| --- | --- |
| `.clean` | terminate |
| `.saving`, or `.unsaved` with a save about to start | wait for the save, then decide again |
| `.unsaved` after a failed save | ask the writer: Retry / Cancel / Quit Anyway |
| `.paused` (changed on disk) | ask the writer: Cancel / Quit Anyway |
| still `.saving` after 10 s (`AutosavePolicy.quitGracePeriod`) | ask the writer: Wait / Quit Anyway |

`quitRequested` asks for an immediate save, so a book with unsaved edits always gets one more
attempt before the writer is asked. A request made during a save that then fails is dropped
(the failure answers it), which is how a quit sees the failure and asks instead of looping.

`AutosaveDriver.prepareToQuit()` sends `quitRequested` and awaits until the decision settles,
returning `.terminate` or `.askWriter(problem)`. The alert's Retry and Wait call it again. A save
that never returns would otherwise hang the quit forever, so after the grace period it returns
`.askWriter(.stillSaving)` while the save keeps running. It never terminates on its own.

It also responds to cancellation: it's declared `async throws(CancellationError)`. Waiting is a
continuation parked in a dictionary. `withTaskCancellationHandler` resumes it when the task is
cancelled, and a second task sleeping on the clock resumes it at the grace deadline. Whichever
comes first wins; the other finds the continuation already gone. That's Swift's equivalent of
`tokio::select!` over a notification, a timer and cancellation, written out by hand.
