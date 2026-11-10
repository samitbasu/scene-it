import Observation

/// Returns once `condition` holds. It checks again each time observable state the condition
/// read changes, so it waits for the change itself rather than for a deadline: a loaded
/// machine makes it slower, never wrong. `condition` must read only `@Observable` state, or
/// a change goes unseen; the suite's time limit ends a real hang.
@MainActor
public func whenObserved(_ condition: () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                changed.resume()
            }
        }
    }
}
