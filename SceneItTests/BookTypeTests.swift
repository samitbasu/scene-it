import Testing
import UniformTypeIdentifiers

@testable import SceneIt

@Test func appBundleIdentifierIsTheShippedOne() {
    #expect(Bundle.main.bundleIdentifier == "com.samitbasu.SceneIt")
}

@Test func bookTypeIsDeclaredAsAPackageWithTheSceneItExtension() {
    #expect(UTType.sceneItBook.identifier == "com.samitbasu.SceneIt.book")
    #expect(UTType.sceneItBook.isDeclared)
    #expect(UTType.sceneItBook.conforms(to: .package))
    #expect(UTType.sceneItBook.preferredFilenameExtension == "sceneit")
}
