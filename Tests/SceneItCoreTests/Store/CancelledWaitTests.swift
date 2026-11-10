import Observation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// A condition that never holds, which says when it has been read under observation.
@MainActor
@Observable
private final class NeverTrue {
    var holds = false
    @ObservationIgnored private var reads = 0
    @ObservationIgnored var observed: CheckedContinuation<Void, Never>?

    /// The second read is the one `whenObserved` makes under observation, as it suspends.
    func read() -> Bool {
        reads += 1
        if reads == 2 { observed?.resume() }
        return holds
    }
}

/// A suite's time limit cancels the test's task, and the waits the store tests use must end
/// then, or a hang lasts until the gate kills the whole run.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CancelledWaitTests {
    @Test func aCancelledObservedWaitEndsWithAnIssue() async {
        let condition = NeverTrue()
        await withKnownIssue("cancelled before the condition held") {
            var wait: Task<Void, Never>?
            await withCheckedContinuation { observed in
                condition.observed = observed
                wait = Task { await whenObserved { condition.read() } }
            }
            wait?.cancel()
            await wait?.value
        }
    }

    @Test func aCancelledWaitForAPermitHoldsNoPermit() async {
        let permits = GatePermits(1)
        #expect(await permits.acquire() == .resumed)
        let second = Task { await permits.acquire() }
        second.cancel()
        #expect(await second.value == .cancelled)
        await permits.release()
        #expect(await permits.acquire() == .resumed, "the cancelled wait took no permit")
    }
}
