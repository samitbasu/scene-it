import Observation
import Synchronization
import Testing

/// Returns once `condition` holds. It checks again each time observable state the condition
/// read changes, so it waits for the change itself rather than for a deadline: a loaded
/// machine makes it slower, never wrong. `condition` must read only `@Observable` state, or
/// a change goes unseen. Cancelling the task (as a suite's time limit does) ends the wait with
/// an issue.
@MainActor
public func whenObserved(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    while !condition() {
        let outcome = await suspend { wake in
            withObservationTracking {
                _ = condition()
            } onChange: {
                wake.resume()
            }
        }
        if outcome == .cancelled {
            Issue.record("cancelled before the condition held", sourceLocation: sourceLocation)
            return
        }
    }
}

/// How a `suspend` ended.
public enum WakeOutcome: Sendable {
    case resumed, cancelled
}

/// Ends a `suspend`, once: by `resume()`, or by the task's cancellation, whichever comes first.
public final class Wake: Sendable {
    private enum State {
        case waiting
        case suspended(CheckedContinuation<WakeOutcome, Never>)
        case ended(WakeOutcome)
    }

    private let state = Mutex(State.waiting)

    fileprivate init() {}

    /// `false` if the wait had already ended, so nothing was woken.
    @discardableResult
    public func resume() -> Bool {
        end(.resumed)
    }

    fileprivate func suspend(_ continuation: CheckedContinuation<WakeOutcome, Never>) {
        let ended = state.withLock { state -> WakeOutcome? in
            if case .ended(let outcome) = state { return outcome }
            state = .suspended(continuation)
            return nil
        }
        if let ended { continuation.resume(returning: ended) }
    }

    @discardableResult
    fileprivate func end(_ outcome: WakeOutcome) -> Bool {
        let woken = state.withLock { state -> (CheckedContinuation<WakeOutcome, Never>?, Bool) in
            switch state {
            case .waiting:
                state = .ended(outcome)
                return (nil, true)
            case .suspended(let continuation):
                state = .ended(outcome)
                return (continuation, true)
            case .ended:
                return (nil, false)
            }
        }
        woken.0?.resume(returning: outcome)
        return woken.1
    }
}

/// Suspends until something `arm` handed the `Wake` to resumes it, or the task is cancelled.
/// `arm` runs before the suspension, in the caller's isolation.
nonisolated(nonsending) public func suspend(_ arm: (Wake) -> Void) async -> WakeOutcome {
    let wake = Wake()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            wake.suspend(continuation)
            arm(wake)
        }
    } onCancel: {
        wake.end(.cancelled)
    }
}
