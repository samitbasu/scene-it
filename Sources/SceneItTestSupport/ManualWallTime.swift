import Foundation
import SceneItCore
import Synchronization

/// The wall time a test sets, to go with `ManualClock`: it moves only when the test advances it.
public final class ManualWallTime: Sendable {
    private let date: Mutex<Date>

    public init(at start: Date = Date()) {
        date = Mutex(start)
    }

    public var now: Date { date.withLock { $0 } }

    public func advance(_ interval: Interval) {
        date.withLock { $0 = $0 + interval }
    }
}
