import SceneItTestSupport
import Testing

private let probe = ParallelismProbe()

/// The gate caps how many core tests run at once, so a test's time limit doesn't count the
/// queue in front of it (ADR 0051). This checks that the toolchain honors the cap; a run
/// without one (`just test`, a filtered run) skips it.
@Test(
    .enabled(if: requestedParallelizationWidth != nil, "no parallelization width was set"),
    arguments: parallelismProbeCases)
func theToolchainHonorsTheParallelizationWidth(_ index: Int) async throws {
    let width = try #require(requestedParallelizationWidth)
    #expect(try await probe.occupy() <= width)
}
