import Foundation
import Testing

/// The best times of one comparison: `work` at a size and at twice that size.
public struct ScalingAttempt: CustomStringConvertible {
    public let size: Duration
    public let doubled: Duration

    public var description: String { "\(size) then \(doubled)" }
}

/// Records an issue unless doubling the input of `work` costs well under four times as much:
/// linear work doubles, quadratic work quadruples.
///
/// Wall-clock time is noisy when other builds or suites load the machine, so both sizes are
/// timed interleaved, a burst of load hitting both, and each keeps the fastest of five runs.
/// A comparison gets three attempts: noise passes on a retry, but quadratic work fails every
/// one. `work(size)` builds its input outside the timing and returns what to time.
@discardableResult
public func expectLinear(
    _ what: String, doubling size: Int, sourceLocation: SourceLocation = #_sourceLocation,
    _ work: (Int) -> () -> Void
) -> ScalingAttempt {
    let (smallWork, largeWork) = (work(size), work(2 * size))
    let clock = ContinuousClock()
    var attempts: [ScalingAttempt] = []
    for _ in 0..<3 {
        var small: [Duration] = []
        var large: [Duration] = []
        for _ in 0..<5 {
            small.append(clock.measure(smallWork))
            large.append(clock.measure(largeWork))
        }
        let attempt = ScalingAttempt(size: small.min()!, doubled: large.min()!)
        attempts.append(attempt)
        if attempt.doubled < attempt.size * 3 + .milliseconds(5) { return attempt }
    }
    Issue.record(
        "\(what) grew faster than linearly from \(size) to \(2 * size): \(attempts)",
        sourceLocation: sourceLocation)
    return attempts.last!
}
