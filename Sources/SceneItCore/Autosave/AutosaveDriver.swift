import Observation

/// Runs an `AutosaveScheduler` against a real clock: one timer task for the next deadline, and
/// the injected `save` for each save the scheduler starts. The scheduler never lets two saves
/// overlap, so the driver doesn't have to.
@MainActor
@Observable
public final class AutosaveDriver<C: Clock<Duration>> {
    /// Saves the book as it is when called. Edits made while it runs are reported as `edited`
    /// and saved by a later call.
    public typealias Save = @MainActor () async throws(SaveError) -> Void

    public private(set) var scheduler = AutosaveScheduler<C.Instant>()

    @ObservationIgnored private let clock: C
    @ObservationIgnored private let save: Save
    @ObservationIgnored private var timer: (deadline: C.Instant, task: Task<Void, Never>)?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(clock: C, save: @escaping Save) {
        self.clock = clock
        self.save = save
    }

    public var state: AutosaveScheduler<C.Instant>.State { scheduler.state }

    public func send(_ event: AutosaveEvent) {
        perform(scheduler.handle(event, at: clock.now))
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// The `applicationShouldTerminate` hook: requests a save and waits until quitting is
    /// either safe or needs the writer's choice. Call it again for the alert's Retry.
    public func prepareToQuit() async -> QuitVerdict {
        send(.quitRequested)
        while true {
            switch state.quitDecision {
            case .settled(let verdict): return verdict
            case .waitForSave: await nextStateChange()
            }
        }
    }

    func wait(until condition: (AutosaveScheduler<C.Instant>.State) -> Bool) async {
        while !condition(state) {
            await nextStateChange()
        }
    }

    private func nextStateChange() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func perform(_ decision: AutosaveScheduler<C.Instant>.Decision) {
        switch decision {
        case .idle:
            cancelTimer()
        case .waitUntil(let deadline):
            // An earlier timer is kept: its tick just re-derives the later deadline, which saves
            // replacing the task on every keystroke.
            if let timer, timer.deadline <= deadline { return }
            cancelTimer()
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
            timer = (deadline, task)
        case .saveNow:
            cancelTimer()
            Task { [weak self, save] in
                let outcome: AutosaveEvent
                do throws(SaveError) {
                    try await save()
                    outcome = .saveSucceeded
                } catch {
                    outcome = .saveFailed(error)
                }
                self?.send(outcome)
            }
        }
    }

    private func cancelTimer() {
        timer?.task.cancel()
        timer = nil
    }
}
