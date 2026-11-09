import Foundation
import Observation

/// The time a view shows ages against, moved on every `period` while `run()` runs, so that "3
/// hours ago" stays true while it's on screen (PLAN §7.2's cards). Its clock and wall time are
/// given, so a test moves it without waiting.
@MainActor
@Observable
public final class MinuteTicker {
    public private(set) var now: Date
    @ObservationIgnored private let period: Interval
    @ObservationIgnored private let wallTime: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Interval) async throws -> Void

    public init<C: Clock<Duration>>(
        clock: C, period: Interval = .minutes(1), wallTime: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.period = period
        self.wallTime = wallTime
        now = wallTime()
        sleep = { try await clock.sleep(for: $0.duration) }
    }

    /// Reads the time now, then again after every `period`, until the task is cancelled.
    public func run() async {
        now = wallTime()
        while true {
            do {
                try await sleep(period)
            } catch {
                return
            }
            now = wallTime()
        }
    }
}
