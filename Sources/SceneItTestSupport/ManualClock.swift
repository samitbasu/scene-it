import Foundation
import SceneItCore
import Synchronization

/// A clock that moves only when a test calls `advance(by:)`, so timing tests never sleep.
public final class ManualClock: Clock, Sendable {
    public struct Instant: InstantProtocol {
        public let offset: Duration

        public init(offset: Duration) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant.start
        var sleepers: [UUID: Sleeper] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }
    /// How many tasks are asleep on it, so a test can wait for one before advancing.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func advance(by interval: Interval) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: interval.duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { state.sleepers[id] = nil }
            return due.values
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}

extension ManualClock.Instant {
    public static let start = ManualClock.Instant(offset: .zero)

    public static func + (instant: ManualClock.Instant, interval: Interval) -> ManualClock.Instant {
        instant.advanced(by: interval.duration)
    }
}
