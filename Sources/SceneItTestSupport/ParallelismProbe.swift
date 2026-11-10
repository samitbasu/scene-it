import Foundation
import Synchronization

/// The width Swift Testing was asked to cap how many tests run at once, if one was set.
public let requestedParallelizationWidth: Int? = ProcessInfo.processInfo
    .environment["SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"].flatMap(Int.init)

/// The arguments of a probe test: more cases than any width the gate sets, so an ignored cap
/// shows as more of them at once.
public let parallelismProbeCases = Array(0..<8)

/// Counts how many test cases are inside `occupy()` at once. The cases of one parameterized
/// test start together, so with no cap the peak is the number of cases; a loaded host only
/// spreads them out and lowers it.
public final class ParallelismProbe: Sendable {
    private let state = Mutex((inside: 0, peak: 0))

    public init() {}

    /// Stays inside for 200 ms without blocking a thread, then returns the peak so far.
    public func occupy() async throws -> Int {
        state.withLock {
            $0.inside += 1
            $0.peak = max($0.peak, $0.inside)
        }
        defer { state.withLock { $0.inside -= 1 } }
        try await Task.sleep(for: .milliseconds(200))
        return state.withLock { $0.peak }
    }
}
