import Foundation
import Observation

/// Saves the book when an `AutosaveDriver` asks. The driver holds its saver weakly, so a store
/// that owns its driver and is also its saver doesn't form a retain cycle.
@MainActor
public protocol AutosaveSaver: AnyObject {
    /// Starts in the same main-actor turn as the scheduler's `.saveNow`, so everything before its
    /// first `await` (taking the snapshot of the book) sees exactly the edits the save covers.
    /// Edits made after that arrive as `edited` and are saved by a later call. It must not call
    /// the driver's `send` itself: the driver reports the outcome.
    func save(_ request: SaveRequest) async throws(SaveError)
}

/// Runs an `AutosaveScheduler` against a real clock: one timer task for the next deadline, and
/// the saver for each save the scheduler starts. The scheduler never lets two saves overlap, so
/// the driver doesn't have to.
@MainActor
@Observable
public final class AutosaveDriver<C: Clock<Duration>> {
    public private(set) var scheduler = AutosaveScheduler<C.Instant>()

    @ObservationIgnored private let clock: C
    @ObservationIgnored private weak var saver: (any AutosaveSaver)?
    @ObservationIgnored private var timer: (deadline: C.Instant, task: Task<Void, Never>)?
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Once `saver` is gone, the book it held is gone too: the driver ignores new events and
    /// lets the app quit.
    public init(clock: C, saver: any AutosaveSaver) {
        self.clock = clock
        self.saver = saver
    }

    public var state: AutosaveScheduler<C.Instant>.State { scheduler.state }

    /// Send `.edited` in the same main-actor turn as the change to the model.
    public func send(_ event: AutosaveEvent) {
        switch event {
        case .saveSucceeded, .saveFailed: break
        default: guard saver != nil else { return }
        }
        perform(scheduler.handle(event, at: clock.now))
        let waiting = waiters.values
        waiters = [:]
        for waiter in waiting { waiter.resume() }
    }

    /// The `applicationShouldTerminate` hook: requests a save and waits until quitting is safe or
    /// needs the writer's choice. A save still running after `AutosavePolicy.quitGracePeriod`
    /// gives `.askWriter(.stillSaving)` and keeps running. Call it again for Retry or Wait.
    public func prepareToQuit() async throws(CancellationError) -> QuitVerdict {
        try await saveAndWait(after: .quitRequested)
    }

    /// Cmd+S, then waits as `prepareToQuit` does: `.terminate` once every edit so far is on disk.
    public func saveAndWait() async throws(CancellationError) -> QuitVerdict {
        try await saveAndWait(after: .saveCommand)
    }

    private func saveAndWait(after request: AutosaveEvent) async throws(CancellationError) -> QuitVerdict {
        guard saver != nil else { return .terminate }
        send(request)
        let deadline = clock.now.advanced(by: AutosavePolicy.quitGracePeriod.duration)
        while true {
            if case .settled(let verdict) = state.quitDecision { return verdict }
            guard clock.now < deadline else { return .askWriter(.stillSaving) }
            try await nextEvent(orUntil: deadline)
        }
    }

    func nextEvent(orUntil deadline: C.Instant?) async throws(CancellationError) {
        let id = UUID()
        let alarm = deadline.map { deadline in
            Task { [weak self, clock] in
                do {
                    try await clock.sleep(until: deadline, tolerance: nil)
                } catch {
                    return
                }
                self?.wake(id)
            }
        }
        defer { alarm?.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wake(id) }
        }
        if Task.isCancelled { throw CancellationError() }
    }

    private func wake(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
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
        case .saveNow(let request):
            cancelTimer()
            guard let saver else { return }
            // Runs synchronously up to the saver's first suspension, so a saver that finishes
            // without suspending re-enters `send` from here.
            Task.immediate { [weak self] in
                let outcome: AutosaveEvent
                do throws(SaveError) {
                    try await saver.save(request)
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
