import Foundation
import Testing
import UniformTypeIdentifiers

@testable import SceneIt

@Test func bookTypeIsNamespacedUnderTheBuiltAppsBundleIdentifier() throws {
    let bundleIdentifier = try #require(Bundle.main.bundleIdentifier)
    #expect(UTType.sceneItBook.identifier == "\(bundleIdentifier).book")
}

@Test func bookTypeIsDeclaredAsAPackageWithTheSceneItExtension() {
    #expect(UTType.sceneItBook.isDeclared)
    #expect(UTType.sceneItBook.conforms(to: .package))
    #expect(UTType.sceneItBook.preferredFilenameExtension == "sceneit")
}
