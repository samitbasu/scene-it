import Testing

@testable import SceneItCore

@Test func bookTypeIsNamespacedUnderTheBundleIdentifier() {
    #expect(SceneItCore.bundleIdentifier == "com.samitbasu.SceneIt")
    #expect(SceneItCore.bookTypeIdentifier == "com.samitbasu.SceneIt.book")
}
