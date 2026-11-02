import SceneItCore
import Testing

@testable import SceneIt

@Test func theTestHostNeverTakesTheAppLock() {
    #expect(ProcessRole.current == .testHost)
    #expect(AppDelegate.instanceLockSummary == .exempt(.testHost))
}
