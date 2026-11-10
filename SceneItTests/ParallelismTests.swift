import Foundation
import Testing

/// Every hosted test runs on the one main thread, so running more of them at once buys no
/// throughput: it stretches each test across everyone else's work, and a test with many turns
/// lasts as long as the whole run (#132, ADR 0039). The scheme caps how many run at once.
@Test func theSchemeCapsHowManyHostedTestsRunAtOnce() throws {
    let setting = ProcessInfo.processInfo.environment["SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"]
    let width = try #require(setting.flatMap(Int.init), "the scheme's test action sets the width")
    #expect((1...2).contains(width))
}
