import SceneItTestSupport
import Testing

private let probe = ParallelismProbe()

/// Every hosted test runs on the one main thread, so running more of them at once buys no
/// throughput: it stretches each test across everyone else's work, and a test with many turns
/// lasts as long as the whole run (#132, ADRs 0039 and 0051). The scheme caps how many run at
/// once; this checks the scheme's setting, and the probe below that the toolchain honors it.
@Test func theSchemeCapsHowManyHostedTestsRunAtOnce() throws {
    let width = try #require(requestedParallelizationWidth, "the scheme's test action sets the width")
    #expect((1...2).contains(width))
}

@Test(arguments: parallelismProbeCases)
func theToolchainHonorsTheSchemesParallelizationWidth(_ index: Int) async throws {
    let width = try #require(requestedParallelizationWidth, "the scheme's test action sets the width")
    #expect(try await probe.occupy() <= width)
}
